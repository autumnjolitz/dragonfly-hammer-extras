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

by-attr
^^^^^^^^^

Status: Implemented


.. code-block:: shell-session

    dfly:~$ ./bin/archive_ctl.sh by-attr --help
    archive_ctl.sh PATH ATTRIBUTE [--set VALUE | --set-from FILENAME ]
    archive_ctl.sh PATH1 [PATH2 [... PATHN]] [--] ATTRIBUTE
    archive_ctl.sh PATH1 [PATH2 [... PATHN]] [--] ATTRIBUTE1,ATTRIBUTE2,ATTRIBUTEN

    available attributes:
        id, type, state, snapshots, sync-beg-tid, sync-end-tid, shared-uuid, unique-uuid, label, prune-min, config, fs-uuid
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
    dfly:~$ archive_ctl pfs-home /Archive2Backup/@@0x00000001b3e06b70:00003
    /Archive2Backup/pfs/volatile
    dfly:~$

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
     my_pfs_name

    QUERY string contains additional options for a per URL configuration:

      pfs-id, p - PFS id (like 2 or 00002)
      bandwidth, b - bandwidth (like 60m)
      delay, d   - delay for mirroring
                   (like 10s)

    Flags are:
      -y --yes    assume yes (default prompt when interactive, no otherwise)
      --validate --t   validate and exit
      --graphite-dsn GRAPHITE_DSN
