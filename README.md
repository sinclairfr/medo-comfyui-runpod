# comfyui-medo

## Version header

The startup script [`print_header()`](start_wrapper.sh:22) now prints revision metadata in the container logs:

- revision number (`rX`)
- date in `DD/YY` format

It is configured through environment variables in [`start_wrapper.sh`](start_wrapper.sh):

- `REVISION` (default: `0`)
- `REVISION_DATE` (default: current date via `date +%d/%y`)

Example:

```bash
REVISION=12 REVISION_DATE=02/26 RUN_AI_TOOLKIT=true
```
