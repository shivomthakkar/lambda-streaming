from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from pathlib import Path


def create_app():
    app = FastAPI(title="Lambda Streaming API")
    
    # Mount static files (templates)
    static_dir = Path(__file__).resolve().parent.parent / "templates"
    if static_dir.exists():
        app.mount("/static", StaticFiles(directory=str(static_dir)), name="static")
    
    from app.routes import register_routes
    register_routes(app)
    
    return app
