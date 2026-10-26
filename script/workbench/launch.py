"""Fixed import path for isolated Python startup; no cwd/PYTHONPATH imports."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
from broker import main
main()
