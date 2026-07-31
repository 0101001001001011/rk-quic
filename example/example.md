# Пример

```dart
import 'package:rk_quic/rk_quic.dart';

void main() {
  // Пакет пока сообщает только о себе. Проба честно отвечает `false`,
  // а не бросает исключение при первом же обращении.
  print('rk_quic $rkQuicVersion, нативная часть: $hasNativeTransport');
}
```
