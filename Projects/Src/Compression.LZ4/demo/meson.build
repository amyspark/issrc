project('demo', 'c')

cc = meson.get_compiler('c')

lzma = cc.find_library('islz4-x64',
    dirs: [meson.current_source_dir() / '..' / 'islz4' / 'x64' / 'Release'],
)

exe = executable('foo', files('foo.c'),
    include_directories: '.',
    dependencies: lzma
)
