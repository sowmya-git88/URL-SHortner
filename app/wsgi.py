"""Gunicorn entrypoint: gunicorn wsgi:app"""
from app import app, init_db

# Idempotent: CREATE TABLE IF NOT EXISTS
init_db(seed=False)
