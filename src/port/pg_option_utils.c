/*-------------------------------------------------------------------------
 *
 * Command line option processing facilities
 *
 * Portions Copyright (c) 1996-2025, PostgreSQL Global Development Group
 * Portions Copyright (c) 1994, Regents of the University of California
 *
 * src/port/pg_option_utils.c
 *
 *-------------------------------------------------------------------------
 */

#include "c.h"

/*
 * is_help_param
 *
 * getopt_long returns '?' for any invalid parameters as well as for the help
 * parameter '-?' without any way to distinguish the two cases.  This helper
 * function can be used to inspect the current parameter in argv in order to
 * determine which case it was.
 */
bool
is_help_param(int argc, char *argv[], int optind)
{
	if (argc > 1 && optind <= argc && strcmp(argv[optind - 1], "-?") == 0)
		return true;

	return false;
}
