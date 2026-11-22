#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""每月清零功能测试。运行：python3 tests/test_monthly_reset.py"""

import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest
from datetime import datetime
from unittest import mock

os.environ["TZ"] = "Asia/Shanghai"
time.tzset()

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_module(name, filename):
    spec = importlib.util.spec_from_file_location(name, os.path.join(BASE, filename))
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


svc = load_module("vps_substore_traffic", "vps-substore-traffic.py")
panel = load_module("vps_substore_panel", "vps-substore-panel.py")

GB = 1024 ** 3
START = int(datetime(2026, 6, 19).timestamp())          # 1781798400
EXPIRE = int(datetime(2027, 6, 19).timestamp())         # 1813334400
NOW_BEFORE = int(datetime(2026, 11, 22, 12).timestamp())
NOW_DEC19 = int(datetime(2026, 12, 19, 0, 0, 1).timestamp())
COUNTERS = {"rx": 1000, "tx": 2000}


def make_cfg(**kw):
    cfg = dict(svc.DEFAULT_CONFIG)
    cfg.update({
        "traffic_mode": "max",
        "quota_bytes": 200 * GB,
        "manual_used_bytes": 22 * GB,
        "billing_start": START,
        "billing_cycle": "year",
        "billing_periods": 1,
        "auto_renew": True,
        "monthly_reset": True,
        "monthly_reset_day": 0,
    })
    cfg.update(kw)
    return svc.normalize_config(cfg)


def panel_state_without_monthly_key():
    # 面板 set_manual_used_bytes 写出的 state：没有 last_monthly_reset_ts
    return {
        "baseline_rx": COUNTERS["rx"], "baseline_tx": COUNTERS["tx"],
        "last_rx": COUNTERS["rx"], "last_tx": COUNTERS["tx"],
        "carried_used_bytes": 22 * GB,
        "cycle_started_at": NOW_BEFORE,
        "last_expire": EXPIRE, "last_reset_at": 0,
        "last_traffic_mode": "max", "last_billing_periods": 1,
        "last_reset_reason": "manual_set_used",
    }


class MonthlyResetTest(unittest.TestCase):
    def test_year_expire_unchanged(self):
        cfg = make_cfg()
        self.assertEqual(cfg["expire"], EXPIRE)
        cfg2, renewed = svc.maybe_auto_renew(cfg)
        self.assertFalse(renewed)
        self.assertEqual(cfg2["expire"], EXPIRE)
        self.assertEqual(cfg2["billing_periods"], 1)

    def test_follow_billing_start_day(self):
        self.assertEqual(svc.monthly_reset_day(make_cfg()), 19)
        self.assertEqual(svc.monthly_reset_day(make_cfg(monthly_reset_day=5)), 5)
        self.assertEqual(svc.monthly_reset_day(make_cfg(monthly_reset=False)), 0)

    def test_next_and_latest(self):
        self.assertEqual(svc.next_monthly_reset_ts(make_cfg(), NOW_BEFORE),
                         int(datetime(2026, 12, 19).timestamp()))
        self.assertEqual(svc.latest_monthly_reset_ts(make_cfg(), NOW_BEFORE),
                         int(datetime(2026, 11, 19).timestamp()))

    def test_first_enable_keeps_manual_used(self):
        """开启当月不能把手填的 22G 冲掉。"""
        with mock.patch.object(svc, "now_ts", return_value=NOW_BEFORE):
            cfg = make_cfg()
            default = svc.initial_state(cfg, COUNTERS)
            st = dict(default)
            st.update(panel_state_without_monthly_key())
            st = svc.update_state(cfg, st, COUNTERS)
            self.assertNotEqual(st["last_reset_reason"], "monthly_reset")
            self.assertEqual(svc.calc_used(st, COUNTERS, "max"), 22 * GB)
            self.assertFalse(svc.clear_manual_used_after_reset(cfg, st))

    def test_reset_on_19th_once(self):
        with mock.patch.object(svc, "now_ts", return_value=NOW_BEFORE):
            cfg = make_cfg()
            st = svc.initial_state(cfg, COUNTERS)
            st["carried_used_bytes"] = 22 * GB
            st["manual_used_bytes_applied"] = 22 * GB
        with mock.patch.object(svc, "now_ts", return_value=NOW_DEC19):
            st = svc.update_state(cfg, st, COUNTERS)
            self.assertEqual(st["last_reset_reason"], "monthly_reset")
            self.assertEqual(st["carried_used_bytes"], 0)
            self.assertEqual(st["last_monthly_reset_ts"], int(datetime(2026, 12, 19).timestamp()))
            # 真实请求里 _load 会在清零后清除手动起始流量
            self.assertTrue(svc.clear_manual_used_after_reset(cfg, st))
            # 同一天反复请求不能重复清零，也不能复活手动已用流量
            st2 = svc.update_state(cfg, st, COUNTERS)
            self.assertEqual(st2, st)
            # 年付到期不被每月清零改动
            self.assertEqual(cfg["expire"], EXPIRE)
            self.assertEqual(cfg["billing_periods"], 1)

    def test_manual_used_not_revived_after_reset(self):
        with mock.patch.object(svc, "now_ts", return_value=NOW_BEFORE):
            cfg = make_cfg()
            st = svc.initial_state(cfg, COUNTERS)
        with mock.patch.object(svc, "now_ts", return_value=NOW_DEC19):
            st = svc.update_state(cfg, st, COUNTERS)
            self.assertTrue(svc.clear_manual_used_after_reset(cfg, st))
            self.assertIsNone(cfg["manual_used_bytes"])
            later = {"rx": 1000 + 3 * GB, "tx": 2000 + 5 * GB}
            st = svc.update_state(cfg, st, later)
            self.assertEqual(svc.calc_used(st, later, "max"), 5 * GB)
            self.assertFalse(svc.clear_manual_used_after_reset(cfg, st))

    def test_day_31_clamps_to_month_end(self):
        cfg = make_cfg(monthly_reset_day=31)
        feb = int(datetime(2027, 2, 28, 0, 0, 1).timestamp())
        self.assertEqual(svc.latest_monthly_reset_ts(cfg, feb),
                         int(datetime(2027, 2, 28).timestamp()))
        jan = int(datetime(2027, 1, 31, 0, 0, 1).timestamp())
        self.assertEqual(svc.next_monthly_reset_ts(cfg, jan),
                         int(datetime(2027, 2, 28).timestamp()))

    def test_disabled_keeps_old_behaviour(self):
        cfg = make_cfg(monthly_reset=False)
        self.assertEqual(svc.latest_monthly_reset_ts(cfg, NOW_DEC19), 0)
        self.assertEqual(svc.reset_reference_ts(cfg), EXPIRE)
        with mock.patch.object(svc, "now_ts", return_value=NOW_DEC19):
            st = svc.initial_state(cfg, COUNTERS)
            st2 = svc.update_state(cfg, st, COUNTERS)
            # 未开启每月清零时只允许原有行为（这里是应用手动已用流量）
            self.assertNotEqual(st2["last_reset_reason"], "monthly_reset")
            self.assertEqual(st2["last_reset_reason"], "manual_used_config")
            self.assertEqual(st2["carried_used_bytes"], 22 * GB)

    def test_userinfo_reset_day_uses_monthly(self):
        with mock.patch.object(svc, "now_ts", return_value=NOW_BEFORE):
            cfg = make_cfg()
            st = svc.initial_state(cfg, COUNTERS)
            info = svc.userinfo(cfg, st, COUNTERS)
            expect = svc.days_until(int(datetime(2026, 12, 19).timestamp()))
            self.assertIn(f"reset_day={expect}", info)
            self.assertIn(f"expire={EXPIRE}", info)

    def test_admin_reset_clears_manual_used(self):
        cfg = make_cfg()
        st = svc.reset_state(cfg, COUNTERS, "manual_api")
        self.assertTrue(svc.clear_manual_used_after_reset(cfg, st))
        self.assertIsNone(cfg["manual_used_bytes"])

    def test_bool_and_day_parsing(self):
        self.assertTrue(svc.normalize_config(make_cfg(monthly_reset="true"))["monthly_reset"])
        self.assertFalse(svc.normalize_config(make_cfg(monthly_reset="no"))["monthly_reset"])
        self.assertEqual(svc.normalize_config(make_cfg(monthly_reset_day=99))["monthly_reset_day"], 31)


class PanelTest(unittest.TestCase):
    def test_edit_billing_writes_monthly_fields(self):
        answers = iter([str(START), "3", "1", "y", "0", "y", "0", ""])
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "cfg.json")
            with mock.patch.object(panel, "CONFIG_PATH", path), \
                 mock.patch("builtins.input", lambda *a: next(answers)):
                cfg = dict(panel.DEFAULT_CONFIG)
                panel.edit_billing(cfg)
            saved = json.load(open(path))
            self.assertEqual(saved["billing_cycle"], "year")
            self.assertEqual(saved["billing_periods"], 1)
            self.assertEqual(saved["expire"], EXPIRE)
            self.assertTrue(saved["monthly_reset"])
            self.assertEqual(saved["monthly_reset_day"], 0)
            self.assertEqual(panel.monthly_reset_day(saved), 19)

    def test_edit_billing_monthly_disabled(self):
        answers = iter([str(START), "3", "1", "n", "0", "n", ""])
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "cfg.json")
            with mock.patch.object(panel, "CONFIG_PATH", path), \
                 mock.patch("builtins.input", lambda *a: next(answers)):
                panel.edit_billing(dict(panel.DEFAULT_CONFIG))
            saved = json.load(open(path))
            self.assertFalse(saved["monthly_reset"])
            self.assertFalse(saved["auto_renew"])

    def test_manual_reset_clears_manual_used(self):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "cfg.json")
            state = os.path.join(d, "state.json")
            json.dump({"carried_used_bytes": 22 * GB}, open(state, "w"))
            cfg = dict(panel.DEFAULT_CONFIG)
            cfg.update({"manual_used_bytes": 22 * GB, "state_file": state})
            with mock.patch.object(panel, "CONFIG_PATH", path), \
                 mock.patch.object(panel, "restart_service", lambda: None), \
                 mock.patch("builtins.input", lambda *a: "yes"):
                panel.manual_reset(cfg)
            saved = json.load(open(path))
            self.assertIsNone(saved["manual_used_bytes"])
            self.assertFalse(os.path.exists(state))


if __name__ == "__main__":
    unittest.main(verbosity=2)
