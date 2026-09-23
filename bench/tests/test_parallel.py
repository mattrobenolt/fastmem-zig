from ec2bench.parallel import parallel


def test_error_isolation() -> None:
    def task(name: str) -> int:
        if name == "bad":
            raise ValueError("expected")
        return 42

    results = parallel(["good", "bad"], task)
    assert results["good"].value == 42
    assert isinstance(results["bad"].error, ValueError)
