#include "postgres.h"
#include "funcapi.h"

PG_MODULE_MAGIC;

extern PGDLLEXPORT void crash(const char *name, const void *private_data, void *arg);

void
crash(const char *name, const void *private_data, void *arg)
{
	abort();
}
