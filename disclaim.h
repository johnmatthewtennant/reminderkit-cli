#ifndef REMINDERKIT_DISCLAIM_H
#define REMINDERKIT_DISCLAIM_H

#include <stddef.h>
#include <sys/types.h>

void reminderkit_disclaim_if_needed(int argc, char *argv[]);
pid_t reminderkit_responsible_pid(void);
const void *reminderkit_embedded_info_plist_bytes(size_t *length);

#endif
