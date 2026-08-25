#!/usr/bin/env python3
"""Host-side reference model for the O6 BIOS PM tuning policy."""

from __future__ import annotations

from dataclasses import dataclass


PROFILE_VENDOR = 0
PROFILE_GB1_2700 = 1
PROFILE_CUSTOM = 2
PROFILE_PARTIAL = 3
PROFILE_MAX = PROFILE_PARTIAL

VOLTAGE_FIXED = 0
VOLTAGE_MODE_MAX = 3
DOMAIN_DISABLED = (0xFFFF, 0xFFFF)
CPU_DOMAIN_FIRST = 3
OPP_DOMAIN_COUNT = 13
SETTINGS_REVISION = 2
SETTINGS_SIGNATURE = 0x54504D52
SETTINGS_LEGACY_SIZE = 209
SETTINGS_V1_SIZE = 265
SETTINGS_CURRENT_SIZE = 273


@dataclass(frozen=True)
class CpuDomain:
    config_index: int
    size: int
    sustained_index: int
    protected_index: int
    frequencies: tuple[int, ...]
    voltages: tuple[int, ...]


CPU_DOMAINS = (
    CpuDomain(
        3,
        7,
        3,
        2,
        (800, 1200, 1500, 1800, 2200, 2400, 2500),
        (750, 750, 790, 790, 790, 850, 920),
    ),
    CpuDomain(
        4,
        7,
        3,
        2,
        (800, 1200, 1500, 1800, 2200, 2500, 2600),
        (750, 750, 790, 790, 790, 850, 920),
    ),
    CpuDomain(
        5,
        7,
        3,
        2,
        (800, 1200, 1500, 1800, 2100, 2200, 2300),
        (750, 750, 790, 790, 790, 850, 890),
    ),
    CpuDomain(
        6,
        6,
        3,
        2,
        (800, 1200, 1500, 1800, 2100, 2200),
        (750, 750, 790, 790, 850, 890),
    ),
)


@dataclass
class Settings:
    profile: int
    frequencies: list[int]
    voltages: list[int]
    enabled_domains: list[int]
    voltage_modes: list[int]
    revision: int = SETTINGS_REVISION
    data_size: int = SETTINGS_CURRENT_SIZE
    signature: int = SETTINGS_SIGNATURE


def default_settings(profile: int = PROFILE_VENDOR) -> Settings:
    frequencies = [0] * 52
    voltages = [0] * 52
    for cpu_index, domain in enumerate(CPU_DOMAINS):
        base = cpu_index * 13
        frequencies[base : base + domain.size] = domain.frequencies
        voltages[base : base + domain.size] = domain.voltages
    return Settings(profile, frequencies, voltages, [0] * 4, [0] * 52)


def validate_settings(settings: Settings, *, engineering: bool) -> None:
    if (
        settings.revision != SETTINGS_REVISION
        or settings.data_size != SETTINGS_CURRENT_SIZE
        or settings.signature != SETTINGS_SIGNATURE
    ):
        raise ValueError("invalid settings header")
    if settings.profile < 0 or settings.profile > PROFILE_MAX:
        raise ValueError("unknown profile")
    if not engineering and settings.profile in (PROFILE_GB1_2700, PROFILE_CUSTOM):
        raise ValueError("engineering profile is disabled")
    if any(value not in (0, 1) for value in settings.enabled_domains):
        raise ValueError("invalid partial-domain state")
    if settings.profile == PROFILE_PARTIAL and not any(settings.enabled_domains):
        raise ValueError("partial profile has no enabled CPU domain")
    if settings.profile not in (PROFILE_CUSTOM, PROFILE_PARTIAL):
        return

    for cpu_index, domain in enumerate(CPU_DOMAINS):
        base = cpu_index * 13
        frequencies = settings.frequencies[base : base + domain.size]
        voltages = settings.voltages[base : base + domain.size]
        modes = settings.voltage_modes[base : base + domain.size]
        if any(value < 800 or value > 3200 or value % 10 for value in frequencies):
            raise ValueError("frequency outside custom limits")
        if any(value < 550 or value > 1250 or value % 10 for value in voltages):
            raise ValueError("voltage outside custom limits")
        if any(value < VOLTAGE_FIXED or value > VOLTAGE_MODE_MAX for value in modes):
            raise ValueError("invalid voltage mode")
        if any(
            current <= previous
            for previous, current in zip(frequencies, frequencies[1:])
        ):
            raise ValueError("frequencies are not increasing")
        if any(current < previous for previous, current in zip(voltages, voltages[1:])):
            raise ValueError("voltages are decreasing")
        protected = domain.protected_index
        if (frequencies[protected], voltages[protected], modes[protected]) != (
            1500,
            790,
            VOLTAGE_FIXED,
        ):
            raise ValueError("protected boot OPP changed")


def partial_headers(enabled_domains: list[int]) -> tuple[tuple[int, int], ...]:
    if len(enabled_domains) != len(CPU_DOMAINS) or not any(enabled_domains):
        raise ValueError("partial profile requires an enabled CPU domain")
    headers = [DOMAIN_DISABLED] * OPP_DOMAIN_COUNT
    for enabled, domain in zip(enabled_domains, CPU_DOMAINS):
        if enabled:
            headers[domain.config_index] = (domain.size, domain.sustained_index)
    return tuple(headers)


def migrate_profile(profile: int, stored_size: int, *, engineering: bool) -> int:
    if stored_size not in (
        1,
        SETTINGS_LEGACY_SIZE,
        SETTINGS_V1_SIZE,
        SETTINGS_CURRENT_SIZE,
    ):
        raise ValueError("unknown settings size")
    maximum = PROFILE_GB1_2700 if stored_size == 1 else PROFILE_MAX
    if stored_size == SETTINGS_LEGACY_SIZE:
        maximum = PROFILE_CUSTOM
    if profile < 0 or profile > maximum:
        profile = PROFILE_VENDOR
    if not engineering and profile in (PROFILE_GB1_2700, PROFILE_CUSTOM):
        profile = PROFILE_VENDOR
    return profile
