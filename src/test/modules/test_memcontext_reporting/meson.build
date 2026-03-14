# Copyright (c) 2026, PostgreSQL Global Development Group

test_memcontext_sources = files(
	'test_memcontext_reporting.c',
)

if host_system == 'windows'
  test_memcontext_sources += rc_lib_gen.process(win32ver_rc, extra_args: [
    '--NAME', 'test_memcontext_reporting',
	'--FILEDESC', 'test_memcontext_reporting - test code for memory context reporting',])
endif

test_memcontext_reporting = shared_module('test_memcontext_reporting',
	test_memcontext_sources,
	kwargs: pg_test_mod_args,
)
test_install_libs += test_memcontext_reporting

tests += {
  'name': 'test_memcontext_reporting',
  'sd': meson.current_source_dir(),
  'bd': meson.current_build_dir(),
  'tap': {
    'env': {
       'enable_injection_points': get_option('injection_points') ? 'yes' : 'no',
    },
    'tests': [
      't/001_memcontext_inj.pl',
    ],
    # The injection points are cluster-wide, so disable installcheck
    'runningcheck': false,
  },
}

