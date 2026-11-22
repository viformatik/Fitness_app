import 'dart:async';
import 'dart:html';
import 'dart:indexed_db';
import 'dart:js' as js;
import 'dart:js_util';
import 'dart:typed_data';

import 'package:hive/hive.dart';
import 'package:hive/src/backend/storage_backend.dart';
import 'package:hive/src/binary/binary_reader_impl.dart';
import 'package:hive/src/binary/binary_writer_impl.dart';
import 'package:hive/src/binary/frame.dart';
import 'package:hive/src/box/keystore.dart';
import 'package:hive/src/registry/type_registry_impl.dart';
import 'package:meta/meta.dart';

/// Handles all IndexedDB related tasks
class StorageBackendJs extends StorageBackend {
  static const _bytePrefix = [0x90, 0xA9];
  final Database _db;
  final HiveCipher? _cipher;
  final String objectStoreName;

  TypeRegistry _registry;

  /// Not part of public API
  StorageBackendJs(this._db, this._cipher, this.objectStoreName,
      [this._registry = TypeRegistryImpl.nullImpl]);

  @override
  String? get path => null;

  @override
  bool supportsCompaction = false;

  bool _isEncoded(Uint8List bytes) {
    return bytes.length >= _bytePrefix.length &&
        bytes[0] == _bytePrefix[0] &&
        bytes[1] == _bytePrefix[1];
  }

  /// Not part of public API
  @visibleForTesting
  dynamic encodeValue(Frame frame) {
    var value = frame.value;
    if (_cipher == null) {
      if (value == null) {
        return value;
      } else if (value is Uint8List) {
        if (!_isEncoded(value)) {
          return value.buffer;
        }
      } else if (value is num ||
          value is bool ||
          value is String ||
          value is List<num> ||
          value is List<bool> ||
          value is List<String>) {
        return value;
      }
    }

    var frameWriter = BinaryWriterImpl(_registry);
    frameWriter.writeByteList(_bytePrefix, writeLength: false);

    if (_cipher == null) {
      frameWriter.write(value);
    } else {
      frameWriter.writeEncrypted(value, _cipher!);
    }

    var bytes = frameWriter.toBytes();
    var sublist = bytes.sublist(0, bytes.length);
    return sublist.buffer;
  }

  /// Not part of public API
  @visibleForTesting
  dynamic decodeValue(dynamic value) {
    if (value is ByteBuffer) {
      var bytes = Uint8List.view(value);
      if (_isEncoded(bytes)) {
        var reader = BinaryReaderImpl(bytes, _registry);
        reader.skip(2);
        if (_cipher == null) {
          return reader.read();
        } else {
          return reader.readEncrypted(_cipher!);
        }
      } else {
        return bytes;
      }
    } else {
      return value;
    }
  }

  /// Not part of public API
  @visibleForTesting
  ObjectStore getStore(bool write) {
    return _db
        .transaction(objectStoreName, write ? 'readwrite' : 'readonly')
        .objectStore(objectStoreName);
  }

  /// Not part of public API
  @visibleForTesting
  Future<List<dynamic>> getKeys({bool cursor = false}) {
    var store = getStore(false);

    if (hasProperty(store, 'getAllKeys') && !cursor) {
      var completer = Completer<List<dynamic>>();
      var request = getStore(false).getAllKeys(null);
      request.onSuccess.listen((_) {
        completer.complete(request.result as List<dynamic>?);
      });
      request.onError.listen((_) {
        completer.completeError(request.error!);
      });
      return completer.future;
    } else {
      return store.openCursor(autoAdvance: true).map((e) => e.key).toList();
    }
  }

  /// Not part of public API
  @visibleForTesting
  Future<Iterable<dynamic>> getValues({bool cursor = false}) {
    var store = getStore(false);

    if (hasProperty(store, 'getAll') && !cursor) {
      var completer = Completer<Iterable<dynamic>>();
      var request = store.getAll(null);
      request.onSuccess.listen((_) {
        var values = (request.result as List).map(decodeValue);
        completer.complete(values);
      });
      request.onError.listen((_) {
        completer.completeError(request.error!);
      });
      return completer.future;
    } else {
      return store.openCursor(autoAdvance: true).map((e) => e.value).toList();
    }
  }

  @override
  Future<int> initialize(
      TypeRegistry registry, Keystore keystore, bool lazy) async {
    _registry = registry;
    var keys = await getKeys();
    if (!lazy) {
      var i = 0;
      var values = await getValues();
      for (var value in values) {
        var key = keys[i++];
        keystore.insert(Frame(key, value), notify: false);
      }
    } else {
      for (var key in keys) {
        keystore.insert(Frame.lazy(key), notify: false);
      }
    }

    return 0;
  }

  @override
  Future<dynamic> readValue(Frame frame) async {
    var value = await getStore(false).getObject(frame.key);
    return decodeValue(value);
  }

  // Request success is not transaction commit. Attach both terminal listeners
  // before issuing any request, schedule the entire batch synchronously, and
  // wait for complete or abort. The future of each request is observed as soon
  // as it is created so neither request nor abort errors escape unhandled.
  Future<void> _committedWrite(
      void Function(ObjectStore, void Function(Future<dynamic>)) issue) async {
    final transaction = _db.transaction(objectStoreName, 'readwrite');
    final terminal = Completer<bool>();
    final completeSubscription = transaction.onComplete.listen((_) {
      if (!terminal.isCompleted) terminal.complete(true);
    });
    final abortSubscription = transaction.onAbort.listen((_) {
      if (!terminal.isCompleted) terminal.complete(false);
    });
    Object? firstError;
    StackTrace? firstStack;
    final requests = <Future<void>>[];

    void fail(Object error, StackTrace stack) {
      firstError ??= error;
      firstStack ??= stack;
      // IndexedDB normally aborts on a request error. Explicit abort also
      // covers synchronous request setup failures returned as failed futures.
      try {
        transaction.abort();
      } catch (_) {
        // It may already be aborting or closed; the terminal event decides.
      }
    }

    void observe(Future<dynamic> request) {
      requests.add(request.then<void>((_) {}, onError: fail));
    }

    try {
      try {
        issue(transaction.objectStore(objectStoreName), observe);
      } catch (error, stack) {
        fail(error, stack);
      }
      await Future.wait(requests);
      final committed = await terminal.future;
      if (!committed || firstError != null) {
        final error = firstError ??
            transaction.error ??
            StateError('IndexedDB transaction was aborted');
        Error.throwWithStackTrace(error, firstStack ?? StackTrace.current);
      }
    } finally {
      await completeSubscription.cancel();
      await abortSubscription.cancel();
    }
  }

  @override
  Future<void> writeFrames(List<Frame> frames) async {
    // Encoding can throw; do it before opening a transaction or changing data.
    final values = <dynamic>[
      for (final frame in frames) frame.deleted ? null : encodeValue(frame),
    ];
    await _committedWrite((store, observe) {
      for (var i = 0; i < frames.length; i++) {
        final frame = frames[i];
        if (frame.deleted) {
          observe(store.delete(frame.key));
        } else {
          observe(store.put(values[i], frame.key));
        }
      }
    });
  }

  @override
  Future<List<Frame>> compact(Iterable<Frame> frames) {
    throw UnsupportedError('Not supported');
  }

  @override
  Future<void> clear() async {
    await _committedWrite((store, observe) {
      observe(store.clear());
    });
  }

  @override
  Future<void> close() {
    _db.close();
    return Future.value();
  }

  @override
  Future<void> deleteFromDisk() async {
    final indexDB = js.context.hasProperty('window')
        ? window.indexedDB
        : WorkerGlobalScope.instance.indexedDB;

    print('Delete ${_db.name} // $objectStoreName from disk');

    // directly deleting the entire DB if a non-collection Box
    if (_db.objectStoreNames?.length == 1) {
      await indexDB!.deleteDatabase(_db.name!);
    } else {
      final db =
          await indexDB!.open(_db.name!, version: 1, onUpgradeNeeded: (e) {
        var db = e.target.result as Database;
        if ((db.objectStoreNames ?? []).contains(objectStoreName)) {
          db.deleteObjectStore(objectStoreName);
        }
      });
      if ((db.objectStoreNames ?? []).isEmpty) {
        await indexDB.deleteDatabase(_db.name!);
      }
    }
  }

  @override
  Future<void> flush() => Future.value();
}
