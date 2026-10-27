"""uvicorn entry point: `uvicorn main:app`. Reads COACH_* settings from the environment. Not deployed anywhere."""
from coach_service.app import create_app

app = create_app()
