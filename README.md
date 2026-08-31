## Requirements

- Linux
- Python 3.11
- NVIDIA GPU with a CUDA 13-compatible driver
- Apptainer 1.4.5
- Graphviz development libraries

## Installation

```bash
python3.11 -m venv .venv
source .venv/bin/activate
```

```bash
curl -LsSf https://astral.sh/uv/0.12.1/install.sh \
| env UV_INSTALL_DIR="$VIRTUAL_ENV/bin" UV_NO_MODIFY_PATH=1 sh
```

```bash
uv pip install \
    --torch-backend=cu130 \
    -r requirements.txt
```

## Model

```bash
hf download \
    Qwen/Qwen3.8-27B \
    --local-dir /path/to/Qwen3.8-27B
```
