import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

// A document the user opened before (PDF or scanned pictures).
// In the "recent" list, `pages` is empty to keep it fast.
// Use DocDb.instance.loadDoc(id) to get the page text.
class SavedDoc {
  final int id;
  final String name;
  final DateTime createdAt;
  final bool isOcr;
  final bool pinned;
  final List<String> pages;
  const SavedDoc({
    required this.id,
    required this.name,
    required this.createdAt,
    required this.isOcr,
    this.pinned = false,
    this.pages = const [],
  });
}

class SavedMsg {
  final String text;
  final bool isUser;
  const SavedMsg(this.text, this.isUser);
}

// Local database on the phone. Every method is safe: if anything goes wrong
// it returns null / an empty list and never crashes the app.
class DocDb {
  DocDb._();
  static final DocDb instance = DocDb._();

  Database? _db;

  // Opened only when first needed (not in main), so tests and startup are safe.
  Future<Database?> _open() async {
    if (_db != null) return _db;
    try {
      final dir = await getDatabasesPath();
      _db = await openDatabase(
        p.join(dir, 'docuchat.db'),
        version: 2,
        onUpgrade: (db, oldVersion, newVersion) async {
          // Version 2 adds pinned files (old phones get the new column).
          if (oldVersion < 2) {
            await db.execute(
              'ALTER TABLE documents ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0',
            );
          }
        },
        onConfigure: (db) async {
          await db.execute('PRAGMA foreign_keys = ON');
        },
        onCreate: (db, version) async {
          await db.execute('''
            CREATE TABLE documents (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              uid TEXT NOT NULL,
              name TEXT NOT NULL,
              created_at INTEGER NOT NULL,
              is_ocr INTEGER NOT NULL DEFAULT 0,
              pinned INTEGER NOT NULL DEFAULT 0,
              pages_json TEXT NOT NULL
            )
          ''');
          await db.execute('''
            CREATE TABLE messages (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              doc_id INTEGER NOT NULL,
              text TEXT NOT NULL,
              is_user INTEGER NOT NULL,
              created_at INTEGER NOT NULL,
              FOREIGN KEY (doc_id) REFERENCES documents (id) ON DELETE CASCADE
            )
          ''');
          await db.execute(
            'CREATE INDEX idx_docs_uid ON documents (uid, created_at)',
          );
          await db.execute(
            'CREATE INDEX idx_msgs_doc ON messages (doc_id, id)',
          );
        },
      );
    } catch (e) {
      debugPrint('Database open failed: $e');
      _db = null;
    }
    return _db;
  }

  // Saves a document for this user. Returns its id, or null if it failed.
  Future<int?> saveDocument({
    required String uid,
    required String name,
    required List<String> pages,
    bool isOcr = false,
  }) async {
    try {
      final db = await _open();
      if (db == null) return null;
      // Limit the size of one page so the database stays small.
      final safe = pages
          .map((t) => t.length > 30000 ? t.substring(0, 30000) : t)
          .toList();
      return await db.insert('documents', {
        'uid': uid,
        'name': name,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'is_ocr': isOcr ? 1 : 0,
        'pages_json': jsonEncode(safe),
      });
    } catch (e) {
      debugPrint('saveDocument failed: $e');
      return null;
    }
  }

  // The user's most recent documents (newest first), without page text.
  Future<List<SavedDoc>> recentDocs(String uid, {int limit = 20}) async {
    try {
      final db = await _open();
      if (db == null) return [];
      final rows = await db.query(
        'documents',
        columns: ['id', 'name', 'created_at', 'is_ocr', 'pinned'],
        where: 'uid = ?',
        whereArgs: [uid],
        orderBy: 'pinned DESC, created_at DESC',
        limit: limit,
      );
      return rows
          .map(
            (r) => SavedDoc(
              id: r['id'] as int,
              name: r['name'] as String,
              createdAt: DateTime.fromMillisecondsSinceEpoch(
                r['created_at'] as int,
              ),
              isOcr: (r['is_ocr'] as int) == 1,
              pinned: (r['pinned'] as int) == 1,
            ),
          )
          .toList();
    } catch (e) {
      debugPrint('recentDocs failed: $e');
      return [];
    }
  }

  // One document with its page text, so the chat can be reopened.
  // The uid check makes sure a user can only open their own documents.
  Future<SavedDoc?> loadDoc(int id, String uid) async {
    try {
      final db = await _open();
      if (db == null) return null;
      final rows = await db.query(
        'documents',
        where: 'id = ? AND uid = ?',
        whereArgs: [id, uid],
        limit: 1,
      );
      if (rows.isEmpty) return null;
      final r = rows.first;
      final pages = (jsonDecode(r['pages_json'] as String) as List)
          .map((e) => e.toString())
          .toList();
      return SavedDoc(
        id: r['id'] as int,
        name: r['name'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
        isOcr: (r['is_ocr'] as int) == 1,
        pages: pages,
      );
    } catch (e) {
      debugPrint('loadDoc failed: $e');
      return null;
    }
  }

  Future<void> addMessage(int docId, String text, bool isUser) async {
    try {
      final db = await _open();
      if (db == null) return;
      await db.insert('messages', {
        'doc_id': docId,
        'text': text,
        'is_user': isUser ? 1 : 0,
        'created_at': DateTime.now().millisecondsSinceEpoch,
      });
    } catch (e) {
      debugPrint('addMessage failed: $e');
    }
  }

  Future<List<SavedMsg>> messages(int docId) async {
    try {
      final db = await _open();
      if (db == null) return [];
      final rows = await db.query(
        'messages',
        where: 'doc_id = ?',
        whereArgs: [docId],
        orderBy: 'id ASC',
      );
      return rows
          .map((r) => SavedMsg(r['text'] as String, (r['is_user'] as int) == 1))
          .toList();
    } catch (e) {
      debugPrint('messages failed: $e');
      return [];
    }
  }

  // How many files and questions this user has saved on this phone.
  Future<({int docs, int questions})> stats(String uid) async {
    try {
      final db = await _open();
      if (db == null) return (docs: 0, questions: 0);
      final d =
          Sqflite.firstIntValue(
            await db.rawQuery(
              'SELECT COUNT(*) FROM documents WHERE uid = ?',
              [uid],
            ),
          ) ??
          0;
      final q =
          Sqflite.firstIntValue(
            await db.rawQuery(
              'SELECT COUNT(*) FROM messages WHERE is_user = 1 AND doc_id IN '
              '(SELECT id FROM documents WHERE uid = ?)',
              [uid],
            ),
          ) ??
          0;
      return (docs: d, questions: q);
    } catch (e) {
      debugPrint('stats failed: $e');
      return (docs: 0, questions: 0);
    }
  }

  // Deletes every saved file (and its chat) of this user.
  Future<void> clearAll(String uid) async {
    try {
      final db = await _open();
      if (db == null) return;
      await db.delete('documents', where: 'uid = ?', whereArgs: [uid]);
    } catch (e) {
      debugPrint('clearAll failed: $e');
    }
  }

  // Pins or unpins a document (pinned files stay at the top of the list).
  Future<void> setPinned(int id, String uid, bool pinned) async {
    try {
      final db = await _open();
      if (db == null) return;
      await db.update(
        'documents',
        {'pinned': pinned ? 1 : 0},
        where: 'id = ? AND uid = ?',
        whereArgs: [id, uid],
      );
    } catch (e) {
      debugPrint('setPinned failed: $e');
    }
  }

  // Changes the name of one saved document.
  Future<void> renameDoc(int id, String uid, String name) async {
    try {
      final db = await _open();
      if (db == null) return;
      await db.update(
        'documents',
        {'name': name},
        where: 'id = ? AND uid = ?',
        whereArgs: [id, uid],
      );
    } catch (e) {
      debugPrint('renameDoc failed: $e');
    }
  }

  // Deletes a document and (automatically) all its messages.
  Future<void> deleteDoc(int id, String uid) async {
    try {
      final db = await _open();
      if (db == null) return;
      await db.delete(
        'documents',
        where: 'id = ? AND uid = ?',
        whereArgs: [id, uid],
      );
    } catch (e) {
      debugPrint('deleteDoc failed: $e');
    }
  }
}