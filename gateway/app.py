"""Single-process gateway: both sets of routes use the same session and job reservations."""

from apps.mongodb_manager.backend.app import create_app as mongo_app
from apps.vps_manager.backend.app import register as register_vps


def create_app(data_dir=None):
    app = mongo_app(data_dir)
    register_vps(app)
    return app


app = create_app()
