#
# Verified 2026-08-03 on Apple M4 / macOS 26.2 / Xcode 26.2 / rustc 1.97.1:
# macosx (arm64+x86_64), iphoneos (arm64) and iphonesimulator (arm64+x86_64)
# each link a C probe against the OTHER_LDFLAGS below, in BOTH Release and
# Debug, and the macOS binaries were run through the C ABI. Before that day not
# one line here had ever been compiled.
#
# The Apple build is now gated by the `packages-apple` job in the root CI of
# the monorepo. See ../apple/build_rust.sh and ../doc/native-build.md.
#
Pod::Spec.new do |s|
  s.name             = 'rk_quic'
  s.version          = '0.1.1'
  s.summary          = 'QUIC and WebTransport for Dart over a native library.'
  s.description      = <<-DESC
Native part of the rk_quic Dart package. Rust behind a C ABI, linked into the
pod framework so `dart:ffi` can open it as rk_quic.framework/rk_quic.
                       DESC
  s.homepage         = 'https://github.com/0101001001001011/rk-quic'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Rob Kim' => 'rk@robkim.kz' }

  s.source           = { :path => '.' }
  s.source_files     = 'Classes/**/*'
  s.dependency 'FlutterMacOS'
  s.platform = :osx, '10.14'

  s.script_phase = {
    :name => 'Build rk_quic (Rust)',
    :script => 'sh "$PODS_TARGET_SRCROOT/../apple/build_rust.sh"',
    :execution_position => :before_compile,
    :output_files => ['${BUILT_PRODUCTS_DIR}/librk_quic.a'],
  }

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    # See the iOS podspec: Dart resolves these symbols at runtime, so nothing
    # at link time references them and only `-force_load` keeps them.
    # `-framework Security -framework CoreFoundation`, и здесь есть ловушка.
    #
    # Rust-staticlib не несёт LC_LINKER_OPTION, поэтому директивы линковки,
    # которые cargo применил бы сам, теряются, когда линкует Xcode.
    #
    # ЛОВУШКА: в RELEASE эти флаги не нужны -- LTO выбрасывает объекты
    # rustls-native-certs целиком, потому что ни один путь от #[no_mangle]
    # точек входа до load_native_certs() не доходит (`ar t | grep -c
    # security_framework` = 0). В DEBUG нет LTO, объекты остаются, и голая
    # линковка падает на 377 неразрешённых символах: 289 даёт отсутствие
    # Security, 88 -- CoreFoundation, и ни один из двух по отдельности не
    # спасает. OTHER_LDFLAGS одна на обе конфигурации, поэтому написан
    # DEBUG-набор.
    #
    # Измерено 2026-08-03. Померив только Release, эта строка осталась бы
    # пустой и ломала бы каждую отладочную сборку потребителя.
    #
    # Цепочка: wtransport 0.7.1 -> rustls-native-certs 0.8.4 ->
    # security-framework 3.7.0. В ios/rk_quic.podspec этого НЕТ: на iOS
    # security-framework отсутствует в графе зависимостей вовсе.
    'OTHER_LDFLAGS' => '-force_load ${BUILT_PRODUCTS_DIR}/librk_quic.a -framework Security -framework CoreFoundation',
  }
  s.swift_version = '5.0'
end
