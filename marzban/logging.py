import logging
import os
from logging.handlers import RotatingFileHandler

# Создаем директорию если нет
os.makedirs('/var/log/marzban', exist_ok=True)

# Настройка логгера
logger = logging.getLogger('marzban')
logger.setLevel(logging.INFO)

# File handler с ротацией
file_handler = RotatingFileHandler(
    '/var/log/marzban/app.log',
    maxBytes=10*1024*1024,  # 10MB
    backupCount=5
)
file_handler.setFormatter(logging.Formatter(
    '%(asctime)s - %(name)s - %(levelname)s - %(message)s'
))

# Console handler для Docker
console_handler = logging.StreamHandler()
console_handler.setFormatter(logging.Formatter(
    '%(asctime)s - %(levelname)s - %(message)s'
))

logger.addHandler(file_handler)
logger.addHandler(console_handler)