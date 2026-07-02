from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MODULE = ROOT / "src" / "WinOfflineUpdate.psm1"
README = ROOT / "README.md"
PROMPT = ROOT / "scripts" / "Invoke-WouClientPrompt.ps1"
COMPUTERS = ROOT / "computers.example.txt"


def test_required_files_exist():
    for path in (MODULE, README, PROMPT, COMPUTERS):
        assert path.exists(), f"missing required file: {path.relative_to(ROOT)}"


def test_windows_powershell_compatible_hash_fallback():
    text = MODULE.read_text(encoding="utf-8")
    assert "[Convert]::ToHexString" not in text
    assert "[BitConverter]::ToString" in text


def test_computer_list_support_is_documented_and_implemented():
    module_text = MODULE.read_text(encoding="utf-8")
    readme_text = README.read_text(encoding="utf-8")
    assert "ComputerListPath" in module_text
    assert "Get-WouComputerList" in module_text
    assert "computers.txt" in readme_text
    assert "-ComputerListPath" in readme_text


def test_fleet_install_requires_downloaded_packages():
    text = MODULE.read_text(encoding="utf-8")
    assert "No update packages found" in text
    assert "Run Save-WouMissingPackages before Invoke-WouFleetInstall" in text
