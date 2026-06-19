from fastapi import APIRouter
from fastapi.responses import FileResponse, StreamingResponse
from pathlib import Path
import asyncio

from app.stream import generate_stream

router = APIRouter()

async def sse_data_generator():
    async for chunk in generate_stream():
        yield f"data: {chunk.strip()}\n\n"


@router.get("/")
async def index():
    """Serve the home page."""
    template_path = Path(__file__).resolve().parent.parent / "templates" / "index.html"
    if template_path.exists():
        return FileResponse(template_path, media_type="text/html")
    return {"message": "Welcome to Lambda Streaming API"}

@router.get("/stream")
async def stream():
    """Stream data with 1-second delays between chunks."""
    return StreamingResponse(
        sse_data_generator(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
        },
    )

@router.get("/hello-world-stream")
async def hello_world_stream():
    """Simple hello world streaming endpoint."""
    async def generate():
        yield "data: Hello\n\n"
        await asyncio.sleep(1)
        yield "data: World!\n\n"
    
    return StreamingResponse(generate(), media_type="text/event-stream")

def register_routes(app):
    """Register all routes with the FastAPI app."""
    app.include_router(router)