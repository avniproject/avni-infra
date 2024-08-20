SECRET_KEY = # secret key add

PREVIOUS_SECRET_KEY = # add details

CONTENT_SECURITY_POLICY_WARNING = False

ENABLE_PROXY_FIX = True

FEATURE_FLAGS = {
    "ENABLE_TEMPLATE_PROCESSING": True,
    "TAGGING_SYSTEM": True,
    "ALLOW_FULL_CSV_EXPORT": True
}

SQLALCHEMY_DATABASE_URI = 'postgresql+psycopg2://<user>:<password>@<url>:5432/supersetdb'

APP_ICON = "/static/assets/images/avni.png"

LOGO_TARGET_PATH = '/'

LOGO_TOOLTIP = "Avni Superset"