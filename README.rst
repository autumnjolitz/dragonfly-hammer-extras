================
hammer-extras
================

Some helpful tools

Example topology:

- ``HAMMER`` primary at /pools/1, /pools/2, ...

  + /pools/1 contains PFS

    - logs
    - backups
    - databases

  + /pools/2 contains PFS:
    - volatile

- ``HAMMER`` replicas at /pools/1.backup, /pools/2.backup, ...


archive_ctl
-------------

In the following example, ``bin/archive_ctl.sh`` is installed at ``/usr/local/bin/archive-ctl``.

.. code-block:: shell-session

    dfly:~$ archive-ctl
    /usr/local/bin/archive-ctl [-d | --debug] [--sudo] [ACTION] [...]

    General flags:
        --sudo   use "sudo -H" when not superuser.

    Debugging flags:
        -d --debug   "set -x" in shell for debugging output.
        --export-debug-internals     allow calling non-exported functions.

    Environment variables:
        ARCHIVE_CTL_AUTO_SUDO
        ARCHIVE_CTL_DEBUG
        ARCHIVE_CTL_EXPORT_DEBUG_INTERNALS
        ARCHIVE_CTL_LIB - search path for common.sh et al.
                          Defaults to "$(realpath "/usr/local/bin/archive-ctl")"

    Available actions:
      in-pfs
      list-mounts
      pfs-id
      is-snapshot
      by-attr
      find-mount-for-pfs
      pfs-home
      pfs-list

  dfly:~$ archive-ctl

pfs-id
^^^^^^^^

.. code-block:: shell-session

    dfly:~$ pfs-id [-p | --pad] PATH [PATH] [... [PATH]]

    General flags:
        -D --delim   character to use as a delimiter (defaults to '\n')
        -p --pad     pad out the id to match '%05d'

    Returns the pfs id of PATH

Example:

.. code-block:: shell-session

    dfly:~$ archive-ctl pfs-id --pad
    00001

    dfly:~$ archive-ctl pfs-id --delim '\t'  /pools/1/pfs/logs /pools/1/pfs/backups /pools/1/pfs/databases
    1   2   3
    dfly:~$


pfs-home
^^^^^^^^^^

Discover the probable canonical top level PFS symbolic link (which points to a destination filename of the format ``@@-1:%05d`` or ``@@0x0123456789abcdef:%05d``) that resides on the root PFS (aka PFS#0).

HAMMER creates a canonical PFS link like ``logs`` which we normally put at a mount point under ``/pfs`` (Example: ``/pools/1/pfs/logs`` points to ``@@-1:00001\n``)

Checks the following paths from the mount point of the HAMMER filesystem:

- /pfs/

- /.pfs/

- /.archive_config/pfs/

Add to the search paths via ``ARCHIVE_CTL_PFS_SEARCH_PATHS``.

Example:

.. code-block:: shell-session

    dfly:~$ $ archive-ctl pfs-home /exports/pfs/logs/
    /pools/1/pfs/logs


in-pfs
^^^^^^^^

Example for a PFS:

.. code-block:: shell-session

    dfly:~$ archive-ctl in-pfs /pools/1/pfs/logs ; echo $?
    0


Example outside a PFS:

.. code-block:: shell-session

    dfly:~$ 2>/dev/null archive-ctl in-pfs /tmp ; echo $?
    1

by-attr
^^^^^^^^^

``by-attr`` is meant to provide the missing unified interface to a PFS for getting/setting behaviors like the snapshot/pruning/reblocking configuration (``config``) or reading the pfs id ``id``.

Status: Implemented


.. code-block:: shell-session

    dfly:~$ ./bin/archive_ctl.sh by-attr --help
    archive-ctl PATH ATTRIBUTE [--set VALUE | --set-from FILENAME ]
    archive-ctl PATH1 [PATH2 [... PATHN]] [--] ATTRIBUTE
    archive-ctl PATH1 [PATH2 [... PATHN]] [--] ATTRIBUTE1,ATTRIBUTE2,ATTRIBUTEN

    General flags:

    -D --delim   character to use as a delimiter (defaults to ',')

    available attributes:
        id, type, state, snapshots, sync-beg-tid, sync-end-tid, shared-uuid, unique-uuid, label, prune-min, config, fs-uuid, home

    dfly:~$


Example:

.. code-block:: shell-session

    dfly:~$ export ARCHIVE_CTL_AUTO_SUDO=1
    dfly:~$ archive_ctl by-attr /var/hammer/pools/1/pfs/logs/snap-20260304-0403  state
    MASTER-SNAPSHOT
    dfly:~$ archive_ctl by-attr /pools/1/pfs/{backups,databases} fs-uuid,shared-uuid,type,label
    b730547b-1746-11f1-b598-9d6b0000024b,82e7d137-8f95-11ec-aa5f-d150991a2d92,MASTER,backups
    b730547b-1746-11f1-b598-9d6b0000024b,4acc554a-577c-11e6-9aa8-d150991a2d92,MASTER,databases
    dfly:~$ archive_ctl list-mounts
    /pools/1
    -snip-
    /pools/2.backup
    dfly:~$ archive_ctl list-pfs /pools/1
    /pools/1/@@-1:00001
    -snip-
    dfly:~$ archive_ctl pfs-home /pools/1/@@-1:00001
    /pools/1/pfs/logs
    dfly:~$ archive_ctl by-attr /pools/2.backup/@@0x00000001b3e06b70:00003 state
    SLAVE-SNAPSHOT
    dfly:~$ archive_ctl by-attr /pools/2.backup/@@0x00000001b3e06b70:00002 state
    SLAVE-TRANSACTION
    dfly:~$ archive_ctl pfs-home /pools/1/@@0x00000001b3e06b70:00003
    /pools/1/pfs/volatile
    dfly:~$ archive-ctl  by-attr -D '\t'  example-null-mount/ id unique-uuid
    00001   568df5e4-1747-11f1-b598-9d6b0000024b
    dfly:~$ archive-ctl  by-attr -D '\t'  example-null-mount/ id unique-uuid | cut -f2
    568df5e4-1747-11f1-b598-9d6b0000024b

mirror
^^^^^^^^

Status: Not implemented

::

    archive_ctl mirror [FLAGS] SOURCE
    archive_ctl mirror [FLAGS] SOURCE DEST1 [DEST2] … [DESTN]

    validates if source/dest can be replicated on. Prompts to create missing DEST pfs. Makes a mirror-copy or stream.

    SOURCE, DEST are:
     MOUNT
     MOUNT/PFS[?QUERY]
     MOUNT?pfs-id=PFS_ID[&QUERY]
     hammer:[//REMOTE/]MOUNT[/PFS][?QUERY]
     hammer:[//REMOTE/]MOUNT[?pfs-id=PFS_ID[&QUERY]]

    PFS is a symbolic link pointing to the HAMMER mount (example: @@-1:PFSID05d).
    Usually present in the root PFS with a bound name like:
     pfs/my_pfs_name
     .pfs/my_pfs_name
     .archive_config/pfs/my_pfs_name

    QUERY string contains additional options for a per URL configuration:

      pfs-id, p - PFS id (like 2 or 00002)
      bandwidth, b - bandwidth (like 60m)
      delay, d   - delay for mirroring
                   (like 10s)

    Flags are:
      -y --yes    assume yes (default prompt when interactive, no otherwise)
      --validate --t   validate and exit
      --graphite-dsn GRAPHITE_DSN
