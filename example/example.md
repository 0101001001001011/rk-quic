# Пример

Касса поднимает точку и сама сообщает браузеру о смене состояния — ничего не
ожидая от него.

```dart
import 'package:rk_quic/rk_quic.dart';

Future<void> main() async {
  // Версия приходит из загруженной библиотеки, а не из константы Dart:
  // если рядом лежит старый артефакт, здесь это и будет видно.
  print('rk_quic ${rkQuicVersion ?? "нативной части нет"}');

  final start = await QuicServer.start(QuicServerConfig(
    bindAddress: '0.0.0.0:4433',
    // Выдаёт rk_pki. Этот пакет сертификаты не минтит намеренно: два
    // удостоверяющих центра в одной установке — это установка, в которой
    // между ними никто не выбирал.
    certificateChainPem: chainPem,
    privateKeyPem: keyPem, // PKCS#8
  ));

  final server = start.server;
  if (server == null) {
    // portInUse, badCertificate, invalidArgument, unsupported — значение,
    // а не исключение (И144). Касса продолжает продавать, браузер продолжает
    // опрашивать REST.
    print('точка не поднялась: $start');
    return;
  }
  print('слушаем порт ${server.port}');

  server.events.listen((event) {
    switch (event) {
      case SessionOpened(:final sessionId):
        // Никто ничего не спрашивал. В этом весь смысл пакета.
        server.send(sessionId, 'задание печати 41 напечатано');
      case SessionClosed(:final sessionId, :final reason):
        // Браузер закрыт, крышка ноутбука опущена, Wi-Fi пропал — с точки
        // зрения кассы это одно и то же: писать в сессию больше некуда.
        print('сессия $sessionId ушла: $reason');
      case StreamMessageReceived(:final message):
        print('от браузера: $message');
      case DatagramReceived(:final message):
        print('датаграмма: $message');
      case EndpointError(:final message):
        print('точке плохо: $message');
      case UnknownQuicEvent(:final kind):
        // Событие из более новой библиотеки. Сохранено целиком, а не отброшено
        // и не подогнано под ближайшее известное.
        print('незнакомое событие: $kind');
    }
  });

  await Future<void>.delayed(const Duration(minutes: 5));
  await server.stop();
}
```
