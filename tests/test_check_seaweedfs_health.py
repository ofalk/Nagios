#!/usr/bin/env python3
"""Unit tests for monitoring/check_seaweedfs_health.py.

The check's `evaluate()` is pure: these tests feed it the same shape of data
`collect()` produces from kubectl/master/volume-server JSON, without needing a
live cluster.
"""

import argparse
import os
import sys
import unittest

REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
sys.path.insert(0, REPO_ROOT)

import check_seaweedfs_health as check  # noqa: E402


def args():
    return argparse.Namespace(
        masters_expected=3,
        volumes_expected=3,
        filers_expected=3,
        admin_expected=1,
        warn_free_pct=10.0,
        crit_free_pct=2.0,
        warn_disk_pct=85.0,
        crit_disk_pct=92.0,
        crit_read_only_pct=10.0,
        crit_underrep_pct=5.0,
    )


def volume_server(index, volume_ids, read_only=(), used_gb=50):
    volumes = [
        {
            "Id": vid,
            "ReplicaPlacement": {"node": 2},
            "ReadOnly": vid in read_only,
        }
        for vid in volume_ids
    ]
    return {
        "url": f"volume-{index}.local:8444",
        "status": {
            "Volumes": volumes,
            "DiskStatuses": [{"all": 100 * 2**30, "used": used_gb * 2**30}],
        },
    }


def base_data(volume_ids=range(100, 110)):
    ids = list(volume_ids)
    return {
        "errors": [],
        "master_pod_used": "localghost-storage-master-0",
        "cluster": {"Leader": "localghost-storage-master-0:9333", "IsLeader": True},
        "dir": {
            "Topology": {
                "Max": 1000,
                "Free": 200,
                "DataCenters": [
                    {
                        "Racks": [
                            {
                                "DataNodes": [
                                    {"Url": f"volume-{i}.local:8444", "Volumes": len(ids), "Max": 333}
                                    for i in range(3)
                                ]
                            }
                        ]
                    }
                ],
            }
        },
        "volume_statuses": [volume_server(i, ids) for i in range(3)],
        "pods": {
            "master": {"total": 3, "ready": 3, "names": ["m0", "m1", "m2"]},
            "volume": {"total": 3, "ready": 3, "names": ["v0", "v1", "v2"]},
            "filer": {"total": 3, "ready": 3, "names": ["f0", "f1", "f2"]},
            "admin": {"total": 1, "ready": 1, "names": ["a0"]},
        },
        "seaweed": {
            "status": {"ready": True},
            "spec": {
                "volume": {
                    "requests": {"storage": "400Gi"},
                    "storageClassName": "longhorn-2-replicas",
                },
                "filer": {"persistence": {"enabled": False}},
            },
        },
        "volume_sts": {
            "spec": {
                "volumeClaimTemplates": [
                    {
                        "spec": {
                            "resources": {"requests": {"storage": "400Gi"}},
                            "storageClassName": "longhorn-2-replicas",
                        }
                    }
                ]
            }
        },
        "filer_sts": {"spec": {"volumeClaimTemplates": []}},
    }


class SeaweedfsHealthTest(unittest.TestCase):
    def test_healthy(self):
        code, summary, details, perf = check.evaluate(base_data(), args())
        self.assertEqual(code, check.OK)
        self.assertIn("free slots 200/1000 (20.0%)", summary)
        self.assertIn("read-only 0", summary)
        self.assertIn("under-replicated 0", summary)
        self.assertIn("free_slots=200", perf)
        self.assertTrue(any("volume servers: 3" in line for line in details))

    def test_original_alert_is_critical_and_says_what_is_scarce(self):
        data = base_data()
        data["dir"]["Topology"].update({"Max": 886, "Free": 9})
        for entry in data["volume_statuses"]:
            entry["status"]["DiskStatuses"][0]["used"] = 69 * 2**30
        # one read-only copy and one under-replicated volume
        data["volume_statuses"][0]["status"]["Volumes"][0]["ReadOnly"] = True
        data["volume_statuses"][1]["status"]["Volumes"].pop()
        code, summary, details, perf = check.evaluate(data, args())
        self.assertEqual(code, check.CRITICAL)
        self.assertIn("free volume slots 9/886 (1.0%)", summary)
        self.assertIn("read-only 1", summary)
        self.assertIn("under-replicated 1", summary)
        for line in details:
            self.assertTrue(line.startswith(("CRITICAL:", "WARNING:", "master pod:")))

    def test_single_read_only_is_warning(self):
        data = base_data()
        data["volume_statuses"][0]["status"]["Volumes"][0]["ReadOnly"] = True
        code, summary, _, _ = check.evaluate(data, args())
        self.assertEqual(code, check.WARNING)
        self.assertIn("1 read-only volume(s)", summary)

    def test_under_replicated_is_warning(self):
        data = base_data()
        data["volume_statuses"][1]["status"]["Volumes"].pop()
        code, summary, _, _ = check.evaluate(data, args())
        self.assertEqual(code, check.WARNING)
        self.assertIn("1 under-replicated volume(s)", summary)

    def test_vct_drift_is_warning(self):
        data = base_data()
        data["volume_sts"]["spec"]["volumeClaimTemplates"][0]["spec"]["resources"]["requests"][
            "storage"
        ] = "80Gi"
        data["filer_sts"]["spec"]["volumeClaimTemplates"] = [{"spec": {}}]
        code, summary, details, _ = check.evaluate(data, args())
        self.assertEqual(code, check.WARNING)
        self.assertTrue(any("storage 80Gi" in line for line in details))
        self.assertTrue(any("filer StatefulSet has 1 PVC template" in line for line in details))

    def test_admin_not_ready_is_warning(self):
        data = base_data()
        data["pods"]["admin"] = {"total": 1, "ready": 0, "names": []}
        code, summary, _, _ = check.evaluate(data, args())
        self.assertEqual(code, check.WARNING)
        self.assertIn("admin 0/1 ready", summary)

    def test_no_leader_is_critical(self):
        data = base_data()
        data["cluster"]["Leader"] = ""
        code, summary, _, _ = check.evaluate(data, args())
        self.assertEqual(code, check.CRITICAL)
        self.assertIn("no Raft leader", summary)

    def test_disk_critical(self):
        data = base_data()
        for entry in data["volume_statuses"]:
            entry["status"]["DiskStatuses"][0]["used"] = 93 * 2**30
        code, summary, _, _ = check.evaluate(data, args())
        self.assertEqual(code, check.CRITICAL)
        self.assertIn("disk 93.0% used", summary)

    def test_master_pod_failure_is_critical(self):
        data = base_data()
        data["pods"]["master"] = {"total": 3, "ready": 1, "names": ["m0"]}
        code, summary, _, _ = check.evaluate(data, args())
        self.assertEqual(code, check.CRITICAL)
        self.assertIn("master 1/3 ready", summary)

    def test_missing_master_data_is_critical(self):
        data = base_data()
        data["dir"] = None
        code, summary, _, _ = check.evaluate(data, args())
        self.assertEqual(code, check.CRITICAL)
        self.assertIn("cannot query", summary)


if __name__ == "__main__":
    unittest.main()
