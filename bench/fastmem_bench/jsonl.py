"""Schema-v2 input and independent libc-probe resolution checks."""

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator

Implementation = Literal["builtin", "glibc", "fastmem_abi", "fastmem_inline", "builtin_const"]
Operation = Literal["copy", "move", "set"]
IMPLEMENTATIONS = ("builtin", "glibc", "fastmem_abi", "fastmem_inline", "builtin_const")
SYMBOLS = ("memcpy", "memmove", "memset")


class Record(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False)


class Perf(Record):
    available: bool
    events: list[str]
    error: str | None


class Evidence(Record):
    address: int = Field(gt=0)
    dli_fname: str = Field(min_length=1)
    dli_fbase: int = Field(gt=0)
    offset: int = Field(ge=0)

    @model_validator(mode="after")
    def check_offset(self) -> Evidence:
        if self.address != self.dli_fbase + self.offset:
            raise ValueError("Resolution address does not equal base plus offset")
        return self


class Resolution(Record):
    glibc: Evidence
    builtin: Evidence


class Meta(Record):
    type: Literal["meta"]
    schema_version: Literal[2] = Field(alias="schema")
    rev: str
    zig: str
    target: str
    cpu: str
    optimize: Literal["ReleaseFast"]
    link_libc: Literal[True]
    chunk_bytes: int = Field(gt=0)
    suite: Literal["quick", "standard", "large", "const", "dist"]
    seed: int = Field(ge=0)
    samples: int = Field(gt=0)
    sample_ms: float = Field(gt=0)
    warmup_ms: float = Field(ge=0)
    impls: list[Implementation] = Field(min_length=1)
    perf: Perf
    fastmem_set: bool
    set_value: int = Field(gt=0, le=255)
    dist_file: str | None
    libc_path: str
    libc_base: int = Field(gt=0)
    resolution: dict[str, Resolution]

    @model_validator(mode="after")
    def check_resolution(self) -> Meta:
        if set(self.resolution) != set(SYMBOLS):
            raise ValueError("Resolution requires memcpy, memmove, and memset")
        if len(self.impls) != len(set(self.impls)):
            raise ValueError("Duplicate implementation in meta")
        local_libraries = set()
        for pair in self.resolution.values():
            if (
                pair.glibc.dli_fname != self.libc_path
                or pair.glibc.dli_fbase != self.libc_base
                or not self.libc_path.endswith("/libc.so.6")
                or pair.builtin.dli_fbase == self.libc_base
                or pair.builtin.dli_fname == self.libc_path
            ):
                raise ValueError("Invalid glibc/builtin resolution")
            local_libraries.add((pair.builtin.dli_fname, pair.builtin.dli_fbase))
        if len(local_libraries) != 1:
            raise ValueError("Builtins do not resolve to one executable")
        return self


class Sample(Record):
    type: Literal["sample"]
    case: str
    op: Operation
    profile: str
    size: float = Field(ge=0)
    src_off: int | None = Field(ge=0)
    dst_off: int | None = Field(ge=0)
    gap: int | None = Field(ge=0)
    impl: Implementation
    sample: int = Field(ge=0)
    iters: int = Field(gt=0)
    ns: float = Field(gt=0)
    cycles: int | None = Field(ge=0)
    instructions: int | None = Field(ge=0)
    ref_cycles: int | None = Field(ge=0)
    time_enabled: int | None = Field(ge=0)
    time_running: int | None = Field(ge=0)

    @model_validator(mode="after")
    def check_counters(self) -> Sample:
        group = (self.cycles, self.instructions, self.time_enabled, self.time_running)
        if any(value is None for value in group) and any(value is not None for value in group):
            raise ValueError("Incomplete perf group")
        if self.time_running is not None and self.time_enabled is not None:
            if self.time_running > self.time_enabled:
                raise ValueError("Perf running time exceeds enabled time")
        elif self.ref_cycles is not None:
            raise ValueError("Ref-cycles without a perf group")
        if self.profile == "const" and self.op != "copy":
            raise ValueError("The const profile requires copy")
        if not self.case.startswith(f"{self.op}/{self.profile}/"):
            raise ValueError("Case ID disagrees with operation/profile")
        return self


class End(Record):
    type: Literal["end"]
    cases: int = Field(ge=0)
    elapsed_ns: int = Field(ge=0)


@dataclass
class Measurement:
    meta: dict[str, Any]
    samples: list[dict[str, Any]]
    end: dict[str, Any]


def applicable(meta: Meta, sample: Sample) -> list[str]:
    if sample.profile == "const":
        allowed = {"builtin_const", "fastmem_inline"}
    else:
        allowed = {"builtin", "glibc", "fastmem_abi", "fastmem_inline"}
        if sample.op == "set" and not meta.fastmem_set:
            allowed -= {"fastmem_abi", "fastmem_inline"}
    return [impl for impl in meta.impls if impl in allowed]


def verify_probe(measurement: Measurement, probe: dict[str, Any]) -> None:
    """Compare paths and offsets, not ASLR-dependent process addresses."""
    meta = measurement.meta
    if meta["libc_path"] != probe.get("libc_path"):
        raise ValueError("Measurement libc path disagrees with libc-probe")
    for name in SYMBOLS:
        reference = probe.get("symbols", {}).get(name, {})
        offset = reference.get("offset")
        if isinstance(offset, str):
            offset = int(offset, 0)
        if meta["resolution"][name]["glibc"]["offset"] != offset:
            raise ValueError(f"Measurement {name} offset disagrees with libc-probe")


def parse(path: Path, *, probe: dict[str, Any] | None = None) -> Measurement:
    try:
        measurement = parse_text(path.read_text())
        if probe is not None:
            verify_probe(measurement, probe)
    except ValueError as error:
        raise ValueError(f"{path}: {error}") from error
    else:
        return measurement


def parse_text(text: str) -> Measurement:
    records = [json.loads(line) for line in text.splitlines() if line.strip()]
    if any(not isinstance(record, dict) for record in records):
        raise ValueError("JSONL records must be objects")
    if not records or records[0].get("type") != "meta" or records[0].get("schema") != 2:
        raise ValueError("Expected schema-v2 meta record")
    if records[-1].get("type") != "end":
        raise ValueError("Incomplete measurement: no end record")
    meta = Meta.model_validate(records[0])
    end = End.model_validate(records[-1])
    samples = [Sample.model_validate(record) for record in records[1:-1]]
    validate_samples(meta, samples, end)
    return Measurement(
        meta.model_dump(by_alias=True),
        [sample.model_dump() for sample in samples],
        end.model_dump(),
    )


def validate_samples(meta: Meta, samples: list[Sample], end: End) -> None:
    seen = set()
    cases: dict[str, Sample] = {}
    for sample in samples:
        if meta.perf.available and sample.cycles is None:
            raise ValueError("Available perf group has null counters")
        key = (sample.case, sample.impl, sample.sample)
        if key in seen:
            raise ValueError(f"Duplicate sample {key}")
        seen.add(key)
        if sample.case in cases:
            first = cases[sample.case]
            fields = ("op", "profile", "size", "src_off", "dst_off", "gap")
            if any(getattr(first, field) != getattr(sample, field) for field in fields):
                raise ValueError(f"Case metadata changed: {sample.case}")
        cases[sample.case] = sample
    if end.cases != len(cases):
        raise ValueError("End case count does not match samples")
    expected = {
        (case, impl, index)
        for case, sample in cases.items()
        for impl in applicable(meta, sample)
        for index in range(meta.samples)
    }
    if seen != expected:
        raise ValueError("Sample set does not match the declared implementations and sample count")
