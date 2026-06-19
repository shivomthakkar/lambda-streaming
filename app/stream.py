import asyncio


async def generate_stream():
    """Async generator for streaming data."""
    for i in range(5):
        yield f"Streaming data {i}\n"
        await asyncio.sleep(1)  # 1 second delay between chunks