import 'dart:async';
import 'package:flutter/material.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:encrypt/encrypt.dart' as encrypt;
import 'package:shared_preferences/shared_preferences.dart';

class OfflineSync {
  static final OfflineSync _instance = OfflineSync._internal();
  factory OfflineSync() => _instance;
  OfflineSync._internal();

  late Database _database;
  late SharedPreferences _sharedPreferences;

  late encrypt.Encrypter _encrypter;
  late encrypt.IV _iv;
  late String _apiEndpoint;
  late String _authToken;

  http.Client _httpClient = http.Client();


  static const int _maxRetries = 3;
  static const int _batchSize = 50;
  static const int _currentSchemaVersion = 2;

  Future<void> initialize(encrypt.Encrypter encrypter,encrypt.IV iv,String apiEndpoint,String authToken) async {

    _encrypter = encrypter;
    _iv = iv;
    _apiEndpoint = apiEndpoint;
    _authToken = authToken;

    _database = await openDatabase(
      join(await getDatabasesPath(), 'offline_sync.db'),
      onCreate: (db, version) async {
        await db.execute(
          'CREATE TABLE sync_queue(id INTEGER PRIMARY KEY, action TEXT, data TEXT, synced INTEGER, retry_count INTEGER, created_at INTEGER)',
        );
        await db.execute(
          'CREATE TABLE schema_version(version INTEGER PRIMARY KEY)',
        );
        await db.execute(
          'CREATE TABLE local_data(id TEXT PRIMARY KEY, data TEXT, last_updated INTEGER)',
        );
        await db.insert('schema_version', {'version': _currentSchemaVersion});
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute(
            'CREATE TABLE local_data(id TEXT PRIMARY KEY, data TEXT, last_updated INTEGER)',
          );
        }
      },
      version: _currentSchemaVersion,
    );

    _sharedPreferences = await SharedPreferences.getInstance();

    await _sharedPreferences.setString(
        'auth_token', _encrypter.encrypt(authToken, iv: _iv).base64);
  }

  Future<void> loadAuthToken() async {
    final encryptedToken = _sharedPreferences.getString('auth_token');
    if (encryptedToken != null) {
      _authToken = _encrypter.decrypt64(encryptedToken, iv: _iv);
    }
  }

  Future<void> addToSyncQueue(String action, Map<String, dynamic> data) async {
    final encryptedData = _encrypter.encrypt(json.encode(data), iv: _iv).base64;
    await _database.insert('sync_queue', {
      'action': action,
      'data': encryptedData,
      'synced': 0,
      'retry_count': 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  // Future<void> _handleConnectivityChange(
  //     List<ConnectivityResult> connectivityResult) async {
  //   if (connectivityResult.any(
  //     (result) => {
  //       ConnectivityResult.mobile,
  //       ConnectivityResult.wifi,
  //       ConnectivityResult.ethernet,
  //       ConnectivityResult.vpn
  //     }.contains(result),
  //   )) {
  //     await syncData();
  //   }
  // }

  Future<bool> syncData() async {
    final unsynced = await _database.query(
      'sync_queue',
      where: 'synced = ? AND retry_count < ?',
      whereArgs: [0, _maxRetries],
      orderBy: 'created_at ASC',
      limit: _batchSize,
    );

    if(unsynced.isNotEmpty){

      for (final item in unsynced) {
        final List<Map<String, dynamic>> batchData = [];

        final decryptedData =
          _encrypter.decrypt64(item['data'] as String, iv: _iv);

        batchData.add({
          'id': item['id'],
          'action': item['action'],
          'data': json.decode(decryptedData),
        });

        //
        try {
          final http.Response response = await _sendToServer('batch_sync', {'batch': batchData});

          if(response.statusCode == 200){
            await _database.update(
              'sync_queue',
              {'synced': 1},
              where: 'id = ?',
              whereArgs: [item['id']],
            );
          }
        }catch(e){
          await _handleSyncError(int.parse(item['id'].toString()), 'Network error');
        }


      }

    // for (int i = 0; i < unsynced.length; i += _batchSize) {
    //   final batch = unsynced.skip(i).take(_batchSize).toList();
    //   await _syncBatch(batch);
    // }
    return true;
    }else{
      return false; 
    }

  }

  // Future<void> _syncBatch(List<Map<String, dynamic>> batch) async {
  //   final List<Map<String, dynamic>> batchData = [];
  //   for (final item in batch) {
  //     final decryptedData =
  //         _encrypter.decrypt64(item['data'] as String, iv: _iv);
  //     batchData.add({
  //       'id': item['id'],
  //       'action': item['action'],
  //       'data': json.decode(decryptedData),
  //     });
  //   }

  //   try {
  //     final http.Response response = await _sendToServer('batch_sync', {'batch': batchData});
  //     final serverResponse = json.decode(response.body);

  //     if(response.statusCode == 200){

  //     }
  //     for (final result in serverResponse['results']) {
  //       if (result['success']) {
  //         await _database.update(
  //           'sync_queue',
  //           {'synced': 1},
  //           where: 'id = ?',
  //           whereArgs: [result['id']],
  //         );
  //       } else {
  //         await _handleSyncError(result['id'], result['error']);
  //       }
  //     }
  //   } catch (e) {
  //     for (final item in batch) {
  //       await _handleSyncError(item['id'], 'Network error');
  //     }
  //   }
  // }

  Future<void> _handleSyncError(int id, String error) async {
    await _database.update(
      'sync_queue',
      {
        'retry_count': 2, //TODO: should update
        'synced': 0,
      },
      where: 'id = ?',
      whereArgs: [id],
    );

    print('Sync failed for item $id: $error');
  }

  Future<http.Response> _sendToServer(
      String action, Map<String, dynamic> data) async {
    if (_apiEndpoint.isEmpty) {
      throw Exception('API endpoint not set');
    }

    final response = await _httpClient.post(
      Uri.parse(_apiEndpoint),
      body: json.encode(data),
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $_authToken',
      },
    );

    if (response.statusCode == 401) {
      // Handle token expiration
      throw Exception('Authentication failed');
    }

    return response;
  }

  Future<void> saveLocalData(String id, Map<String, dynamic> data) async {
    final encryptedData = _encrypter.encrypt(json.encode(data), iv: _iv).base64;
    await _database.insert(
      'local_data',
      {
        'id': id,
        'data': encryptedData,
        'last_updated': DateTime.now().millisecondsSinceEpoch,
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );

    // Add to sync queue
    await addToSyncQueue('update_data', {'id': id, 'data': data});
  }

  Future<Map<String, dynamic>?> readLocalData(String id) async {
    final result = await _database.query(
      'local_data',
      where: 'id = ?',
      whereArgs: [id],
    );

    if (result.isNotEmpty) {
      final encryptedData = result.first['data'] as String;
      final decryptedData = _encrypter.decrypt64(encryptedData, iv: _iv);
      return json.decode(decryptedData);
    }

    return null;
  }

  Future<List<Map<String, dynamic>>> readAllLocalData() async {
    final results = await _database.query('local_data');
    return results.map((row) {
      final encryptedData = row['data'] as String;
      final decryptedData = _encrypter.decrypt64(encryptedData, iv: _iv);
      return {
        'id': row['id'],
        'data': json.decode(decryptedData),
        'last_updated': row['last_updated'],
      };
    }).toList();
  }

  Future<void> dispose() async {
    await _database.close();
  }

  @visibleForTesting
  OfflineSync.withDependencies({
    required Database database,
    required http.Client httpClient,
    required SharedPreferences sharedPreferences,
  }) {
    _database = database;
    _httpClient = httpClient;
    _sharedPreferences = sharedPreferences;
  }

  @visibleForTesting
  String encryptData(Map<String, dynamic> data) {
    return _encrypter.encrypt(json.encode(data), iv: _iv).base64;
  }
}
