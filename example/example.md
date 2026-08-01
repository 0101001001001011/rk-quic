# Пример

```dart
import 'package:rk_quic/rk_quic.dart';

void main() {
  // Версия приходит из загруженной библиотеки, а не из константы Dart:
  // если рядом лежит старый артефакт, здесь это и будет видно.
  print('rk_quic ${rkQuicVersion ?? "нативной части нет"}');

  final probe = probeNativeLibrary();
  switch (probe.outcome) {
    case NativeLoadOutcome.loaded:
      print('нативный транспорт есть: ${probe.path}');
    case NativeLoadOutcome.unsupportedPlatform:
      // Браузер. Не отказ: он клиент этой точки, а не её хост.
      print('здесь нативной части не бывает');
    case NativeLoadOutcome.libraryMissing:
    case NativeLoadOutcome.symbolMissing:
    case NativeLoadOutcome.abiMismatch:
      // Ничего не брошено и ничто не упало — можно просто продолжить
      // без нативного транспорта.
      print('нативного транспорта нет: $probe');
  }
}
```
