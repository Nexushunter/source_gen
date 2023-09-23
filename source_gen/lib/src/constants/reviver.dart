import 'dart:mirrors';

import 'package:analyzer/dart/constant/value.dart';

import '../../source_gen.dart';
import 'reader.dart';

/// Revives a [ConstantReader] to an instance in memory using Dart mirrors.
///
/// Converts a serialized [DartObject] and transforms it into a fully qualified
/// instance of the object to be consumed.
///
/// An intended usage of this is to provide those creating Generators a simpler
/// way to initialize their annotations as in memory instances. This allows for
/// cleaner and smaller implementations that don't have an underlying knowledge
/// of the [ConstantReader]. This simplfies cases like the following:
///
/// ```dart
/// // Defined within a builder library and exposed for consumers to extend.
/// /// This [Delegator] delegates some complex processing.
/// abstract class Delegator<T> {
///   const Delegator();
///
///   T call([dynamic]);
/// }
///
/// // Consumer library
/// /// My CustomDelegate callable to be used in a builder
/// class CustomDelegate implements Delegator<ReturnType> {
///   const CustomDelegate();
///
///   @override
///   ReturnType call(Map<String,String> args) async {
///     // My implementation details.
///   }
/// }
/// ```
///
/// Where a library exposes an interface that the user is to implement by
/// the library doesn't need to know all of the implementation details.
class Reviver {
  final ConstantReader reader;
  const Reviver(this.reader);
  Reviver.fromDartObject(DartObject? object) : this(ConstantReader(object));

  /// Recurively build the instance and return it.
  ///
  /// This may return null when the declaration doesn't exist within the
  /// system or the [reader] is null.
  ///
  /// In the event the reader is a primative type it returns that value.
  /// Collections are iterated and revived.
  /// Otherwise a fully qualified instance is returned.
  dynamic toInstance() {
    if (reader.isNull) {
      return null;
    } else if (reader.isBool) {
      return reader.boolValue;
    } else if (reader.isDouble) {
      return reader.doubleValue;
    } else if (reader.isInt) {
      return reader.intValue;
    } else if (reader.isList) {
      return reader.listValue
          .map((e) => Reviver.fromDartObject(e).toInstance())
          .toList(growable: false);
    } else if (reader.isSet) {
      return reader.setValue
          .map((e) => Reviver.fromDartObject(e).toInstance())
          .toSet();
    } else if (reader.isString) {
      return reader.stringValue;
    } else if (reader.isMap) {
      return reader.mapValue.map(
        (key, value) => MapEntry(
          Reviver.fromDartObject(key).toInstance(),
          Reviver.fromDartObject(value).toInstance(),
        ),
      );
    } else if (reader.isLiteral) {
      return reader.literalValue;
    } else if (reader.isType) {
      return reader.typeValue;
    } else if (reader.isSymbol) {
      return reader.symbolValue;
    } else {
      final isEnum = reader.instanceOf(const TypeChecker.fromRuntime(Enum));

      final revivable = reader.revive();

      // Flatten the list of libraries
      final entries = Map.fromEntries(currentMirrorSystem().libraries.entries)
          .map((key, value) => MapEntry(key.pathSegments.first, value));

      // Grab the library from the system
      final libraryMirror = entries[revivable.source.pathSegments.first];
      if (libraryMirror == null || libraryMirror.simpleName == Symbol.empty) {
        throw Exception('Library missing');
      }

      // Determine the declaration being requested. Split on . when an enum is passed in.
      var declKey = Symbol(revivable.source.fragment);
      if (isEnum) {
        // The accessor when the entry is an enum is the ClassName.value
        declKey = Symbol(revivable.accessor.split('.')[0]);
      }

      final decl = libraryMirror.declarations[declKey] as ClassMirror?;
      if (decl == null) {
        throw Exception('Declaration missing');
      }

      // Handle the enum case
      if (decl.isEnum) {
        final values = decl.getField(const Symbol('values')).reflectee as List;
        return values[reader.objectValue.getField('index')!.toIntValue()!];
      }

      final positionalArguments = revivable.positionalArguments
          .map((e) => Reviver.fromDartObject(e).toInstance())
          .toList(growable: false);

      final namedArguments = revivable.namedArguments.map(
        (key, value) => MapEntry(
          Symbol(key),
          Reviver.fromDartObject(value).toInstance(),
        ),
      );

      return decl
          .newInstance(
            Symbol(revivable.accessor),
            positionalArguments,
            namedArguments,
          )
          .reflectee;
    }
  }
}
