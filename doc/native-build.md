# Сборка нативной части

`rk_quic` — **FFI-плагин Flutter**. Cargo вызывается из файлов сборки на
платформу; артефакт отдаётся инструменту Flutter, который кладёт его в
приложение. Каталога `hook/` здесь нет и быть не должно — почему, сказано ниже.

## Что должно стоять у потребителя

| Цель | Сверх Rust |
| --- | --- |
| Windows | Visual Studio с рабочей нагрузкой C++ (нужны CMake и MSBuild); цель `x86_64-pc-windows-msvc` |
| Linux | `clang cmake ninja-build pkg-config libgtk-3-dev`; цель `x86_64-unknown-linux-gnu` |
| Android | Android SDK, NDK, JDK 17; цели `aarch64-linux-android`, `armv7-linux-androideabi`, `x86_64-linux-android` |
| macOS / iOS | Xcode, CocoaPods (то есть Ruby); цели `aarch64-apple-darwin`, `x86_64-apple-darwin`, `aarch64-apple-ios`, `aarch64-apple-ios-sim` |
| Web | ничего: в браузере нативной части нет по устройству |

Кросс-компиляцию не отменяет ни один механизм сборки: cargo всё равно нужен
линкер NDK для Android и Xcode для Apple.

## Три пути к cargo, а не один

Это неприятно, и лучше знать заранее, чем открывать заново.

| Платформы | Как вызывается cargo |
| --- | --- |
| Windows, Linux | CMake: `src/CMakeLists.txt`, путь отдаётся в `rk_quic_bundled_libraries` |
| Android | Gradle напрямую: задача `rkQuicCargoBuild` в `android/build.gradle`, результат кладётся в `jniLibs.srcDirs` |
| macOS, iOS | `apple/build_rust.sh` из фазы-скрипта podspec |

Причина у каждого расхождения своя, и обе стоят того, чтобы быть записанными.

### Android: CMake здесь не работает, и «зелёная сборка» это скрывает

Очевидная форма — та же, что на Windows и Linux: `externalNativeBuild.cmake.path`
на общий `src/CMakeLists.txt`, cargo внутри `add_custom_target`, копирование в
`CMAKE_LIBRARY_OUTPUT_DIRECTORY`. Происходит следующее, ровно в таком порядке.

1. При `project(... LANGUAGES NONE)` AGP падает на этапе конфигурации с голым
   `java.lang.NullPointerException` в `CmakeFileApiV1Kt.readCmakeFileApiReply`:
   он читает ответ file API у CMake и ждёт объект `toolchains`, а CMake выдаёт
   его только для проекта с объявленным языком. Ни сообщения, ни файла, ни строки.

2. `LANGUAGES C` эту стену проходит — и дальше **сборка успешна, а библиотеки
   нет**. Читается в `.cxx/<config>/<hash>/<abi>/android_gradle_build.json`: AGP
   видит пользовательскую цель как
   `"rk_quic_cargo::@…": { "artifactName": "rk_quic_cargo" }` **без ключа
   `output`**, потому что custom target не производит библиотеки, которую CMake
   мог бы назвать. После этого AGP просит ninja собрать пустой список целей —
   cargo не запускается вовсе, и шаг копирования, подвешенный к цели, которую
   никто не вызывает, сработать не может. Проверено распаковкой APK: 38,9 МБ,
   `libflutter.so` и `libapp.so` на три ABI, `librk_quic.so` нет.

Зелёная сборка, отгружающая пустоту, — худший из возможных исходов, поэтому
путь через CMake на Android не чинится, а оставляется.

Ещё одна мина того же класса, найденная тут же: если собрать и `x86`, в APK
появится `lib/x86/librk_quic.so` в каталоге, где нет `libflutter.so` — Flutter
32-битный x86 не поставляет. Android выбирает каталог по основному ABI
устройства и грузит то, что в нём лежит, поэтому 32-битное x86-устройство
выбрало бы каталог с одной нашей библиотекой и упало. Набор по умолчанию
совпадает ровно с тем, что кладёт Flutter; `x86` собирается по требованию
(`-PrkQuicAbiFilter=x86`).

### Apple: внутрь пода, а не рядом с ним

Шаблоны Podfile у Flutter содержат `use_frameworks!`, поэтому под собирается как
`rk_quic.framework`, и Dart открывает `rk_quic.framework/rk_quic` — один
двоичный файл Mach-O. На Windows и Linux хватало отдать CMake абсолютный путь и
дать инструменту скопировать файл рядом с runner; внутри фреймворка никакого
«рядом» нет.

Поэтому Apple получает **статический** архив, а `-force_load` в `OTHER_LDFLAGS`
втягивает все объекты в двоичный файл фреймворка. Именно `-force_load`, а не
обычный `-l`: ни Objective-C, ни Swift эти символы не упоминают — их ищет Dart по
имени во время работы, — и обычная линковка выбросила бы весь архив как
неиспользуемый.

**Ни один абзац про Apple сборкой не проверен.** Mac в распоряжении нет; всё
вычитано из инструментов. Первому, у кого будет Xcode, проверять в таком
порядке:

1. Собирается ли `aws-lc-rs` под цели Apple. Это **самый вероятный отказ**, а не
   podspec: у него сборочный скрипт на C, которому нужны CMake и подходящий
   компилятор. На Android этот шаг проверен и проходит — но только после того,
   как заданы и `CARGO_TARGET_<TRIPLE>_LINKER`, и `AR_<triple>`; без второго
   `cc-rs` ищет несуществующий `aarch64-linux-android-ar` и падает. У Apple
   ожидается тот же класс отказа с другими именами.
2. Существует ли вообще двоичный файл фреймворка (`ls …/rk_quic.framework/rk_quic`).
3. Перечисляет ли `nm -gU` на нём `_rk_quic_version` и `_rk_quic_server_start`.
4. Есть ли срез симулятора наравне со срезом устройства.
5. Отдельно для iOS: приложению нужно право слушать UDP-порт, и в фоне сокет
   закрывается системой. Точка QUIC на iOS осмысленна только пока приложение на
   переднем плане — это ограничение платформы, а не пакета.

## Файлы и назначение каждого

| Файл | Зачем |
| --- | --- |
| `rust/` | крейт: `Cargo.toml`, `Cargo.lock`, `src/` |
| `src/rk_quic.h` | C ABI, сказанный один раз; сверяется `test/abi_surface_test.dart` |
| `src/CMakeLists.txt` | отображение платформы CMake на тройку Rust, вызов cargo (Windows и Linux) |
| `windows/CMakeLists.txt` | подключает `src/`, отдаёт путь в `rk_quic_bundled_libraries` |
| `linux/CMakeLists.txt` | то же |
| `android/build.gradle` | задача `rkQuicCargoBuild`, отображение ABI на тройку и на обёртку clang из NDK, `jniLibs.srcDirs` |
| `android/settings.gradle` | требуется Gradle |
| `android/src/main/AndroidManifest.xml` | требуется библиотекой Android |
| `apple/build_rust.sh` | собирает статический архив, который Xcode линкует в под |
| `ios/rk_quic.podspec`, `macos/rk_quic.podspec` | CocoaPods: фаза-скрипт и `-force_load` |

Плюс блок `flutter.plugin.platforms` в `pubspec.yaml`, без которого инструмент
Flutter ни на что из перечисленного не смотрит.

Одно отображение вывести из другого нельзя, и ровно здесь ошибаются: обёртка
clang в NDK для 32-битного ARM называется `armv7a-linux-androideabi`, а тройка
Rust — `armv7-linux-androideabi`.

## Почему не `hook/build.dart`

Измерено 2026-07-31
(`.superpowers/sdd/2026-07-31-native-pipeline/task-2-report.md`): на Flutter
3.32.4 stable хуки доводят библиотеку до **нуля целей из шести**, потому что
возможность закрыта каналом SDK, а `flutter config --enable-native-assets`
принимается и не действует. Хуже, чем бесполезно: **само наличие каталога
`hook/`** ломает `dart run`, `dart test` и `flutter build` у любого потребителя
пакета на любой платформе. Цена ошибки — не «одна цель не собралась», а «не
собирается ничего».

Условие пересмотра одно и проверяется командой: `flutter config --list`
перестаёт печатать `(Unavailable)` рядом с `enable-native-assets` на
закреплённой версии Flutter.

## Сборка руками

```sh
cd packages/rk_quic/rust
cargo build --release                                   # хост
cargo build --release --target aarch64-linux-android    # нужен линкер NDK
cargo test
cargo clippy --all-targets -- -D warnings
```

Тесты пакета находят результат сами; `RK_QUIC_LIBRARY=<путь>` направляет их в
другое место — например, на артефакт, который уже попал в собранное приложение.
