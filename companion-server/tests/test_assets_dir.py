import importlib
import shutil

import render.brand as brand


def test_assets_dir_env_override(tmp_path, monkeypatch):
    # A deployed copy sets COMPANION_ASSETS_DIR; fonts and brand SVGs must resolve from there.
    shutil.copytree(brand.FONT_DIR, tmp_path / "fonts")
    shutil.copytree(brand.BRAND_SVG_DIR, tmp_path / "brand" / "svg")
    monkeypatch.setenv("COMPANION_ASSETS_DIR", str(tmp_path))
    try:
        b = importlib.reload(brand)
        assert b.FONT_DIR == tmp_path / "fonts"
        assert b.BRAND_SVG_DIR == tmp_path / "brand" / "svg"
        assert (b.FONT_DIR / "SairaExtraCondensed-ExtraBold.ttf").is_file()
    finally:
        monkeypatch.undo()  # restore the caller's environment before reloading, so later tests see it
        importlib.reload(brand)


def test_assets_dir_defaults_to_repo(monkeypatch):
    monkeypatch.delenv("COMPANION_ASSETS_DIR", raising=False)
    try:
        b = importlib.reload(brand)
        assert b.ASSETS_DIR == b.REPO / "assets"
    finally:
        monkeypatch.undo()
        importlib.reload(brand)
