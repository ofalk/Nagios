Nagios
======

Nagios plugins and scripts that I've written over time and now
want to share with you. There are a lot of quite simple scripts
here, but they might help you.


Most SSH based scripts have been developed during my time at a
bigger company, where we had (root) SSH keys on all machines.


Most SNMP based scripts have been developed during earlier times.

To be able to use check_snmp_process_alarm_wrapper.pl, you have to
create a link next to the script pointing to check_snmp_process.
Both the Perl version as well as the C version should work fine.
C version available here: http://nagios.manubulon.com/

Documentation you ask? Learn Perl, Python and Bash and you'll
understand the scripts.

## SeaweedFS

`check_seaweedfs_health.py` is the current cluster health check:

- reports free **volume-file slots** as a percentage, not as "storage
  capacity" (`Topology.Free` is `Max - Volumes`, so a server can have very few
  slots while 30% of the disk is still free);
- reports disk usage, read-only volumes, under-replicated volumes, component
  readiness, `Seaweed.status.ready` and `VolumeClaimTemplates` drift;
- supports `--namespace`, `--seaweed-name`, `--master-pod`, the expected
  replica counts and the warning/critical thresholds.

The older `check_seaweedfs_health.sh` is kept for compatibility. Its
"Low storage capacity" message reflects free volume slots, not free bytes;
prefer the Python check for new deployments.

