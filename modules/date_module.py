from modules.module_base import ModuleBase
from PIL import Image
from datetime import datetime
from utils.tiny_font import draw_tiny_text

class DateModule(ModuleBase):
    def __init__(self):
        super().__init__(11)

    def render(self, width):
        image = super().render(width)
        current_date = datetime.now().strftime("%d%m")
        date_format = "DDMM"  # Format for displaying date. Can be "DDMM" or "MMDD"

        # Draw DD and MM at their respective locations
        draw_tiny_text(image, current_date[:2], 
                       0 if date_format == "DDMM" else 2, 
                       0 if date_format == "DDMM" else 6)
        draw_tiny_text(image, current_date[2:4], 
                       2 if date_format == "DDMM" else 0, 
                       6 if date_format == "DDMM" else 0)

        return image
    