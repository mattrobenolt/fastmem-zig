"""Schema-v1 measurement input."""

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field

Implementation = Literal["builtin", "fastmem", "libc"]


class Record(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False)


class Perf(Record):
    available: bool
    events: list[str]
    error: str | None


class Meta(Record):
    type: Literal["meta"]
    schema_version: Literal[1] = Field(alias="schema")
    rev: str
    zig: str
    target: str
    cpu: str
    optimize: str
    link_libc: bool
    chunk_bytes: int = Field(gt=0)
    suite: Literal["quick", "standard", "dist"]
    seed: int = Field(ge=0)
    samples: int = Field(gt=0)
    sample_ms: float = Field(gt=0)
    warmup_ms: float = Field(ge=0)
    impls: list[Implementation] = Field(min_length=1)
    perf: Perf


class Sample(Record):
    type: Literal["sample"]
    case: str
    op: Literal["copy", "move"]
    profile: str
    size: float = Field(ge=0)
    src_off: int = Field(ge=0)
    dst_off: int = Field(ge=0)
    gap: int | None
    impl: Implementation
    sample: int = Field(ge=0)
    iters: int = Field(gt=0)
    ns: float = Field(ge=0)
    cycles: int | None
    instructions: int | None
    ref_cycles: int | None


class End(Record):
    type: Literal["end"]
    cases: int = Field(ge=0)
    elapsed_ns: int = Field(ge=0)


@dataclass
class Measurement:
    meta: dict[str, Any]
    samples: list[dict[str, Any]]
    end: dict[str, Any]


def parse(path: Path) -> Measurement:
    try:
        return parse_text(path.read_text())
    except ValueError as error:
        raise ValueError(f"{path}: {error}") from error


def parse_text(text: str) -> Measurement:
    records = [json.loads(line) for line in text.splitlines() if line.strip()]
    if not records or records[0].get("type") != "meta" or records[0].get("schema") != 1:
        raise ValueError("Expected schema-v1 meta record")
    if records[-1].get("type") != "end":
        raise ValueError("Incomplete measurement: no end record")
    meta = Meta.model_validate(records[0])
    end = End.model_validate(records[-1])
    samples = [Sample.model_validate(record) for record in records[1:-1]]
    seen = set()
    for sample in samples:
        key = (sample.case, sample.impl, sample.sample)
        if key in seen:
            raise ValueError(f"Duplicate sample {key}")
        seen.add(key)
    cases = {sample.case for sample in samples}
    if end.cases != len(cases):
        raise ValueError("End case count does not match samples")
    expected = {
        (case, impl, index)
        for case in cases
        for impl in meta.impls
        for index in range(meta.samples)
    }
    if seen != expected:
        raise ValueError("Sample set does not match the declared implementations and sample count")
    return Measurement(
        meta.model_dump(by_alias=True),
        [sample.model_dump() for sample in samples],
        end.model_dump(),
    )
