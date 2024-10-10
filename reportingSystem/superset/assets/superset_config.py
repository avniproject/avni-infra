import os

# secret key add
SECRET_KEY = os.getenv('SUPERSET_SECRET_KEY')

CONTENT_SECURITY_POLICY_WARNING = False

ENABLE_PROXY_FIX = True

FEATURE_FLAGS = {
    "ENABLE_TEMPLATE_PROCESSING": True,
    "TAGGING_SYSTEM": True,
    "ALLOW_FULL_CSV_EXPORT": True,
    "DASHBOARD_RBAC" :True
}

DB_USER = os.getenv('SUPERSET_DB_USER')
DB_PASSWORD = os.getenv('SUPERSET_DB_PASSWORD')
DB_URL = os.getenv('SUPERSET_DB_URL')
DB_PORT = os.getenv('SUPERSET_DB_PORT')
DB_NAME = os.getenv('SUPERSET_DB_NAME')

SQLALCHEMY_DATABASE_URI = "postgresql+psycopg2://"+DB_USER+":"+DB_PASSWORD+"@"+DB_URL+":"+DB_PORT+"/"+DB_NAME

APP_ICON = "/static/assets/images/avni.png"

LOGO_TARGET_PATH = '/'

LOGO_TOOLTIP = "Go Home"

APP_NAME = "Avni Superset"

FAVICONS = [{"href": "/static/assets/images/avni-favicon.ico"}]
