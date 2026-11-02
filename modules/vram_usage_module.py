from modules.module_base import ModuleBase
from utils.metering_utility import MeteringUtility
from PIL import Image

class VramUsageModule(ModuleBase):
    def __init__(self, height=1):
        super().__init__(height)  # module height
        self.metering_utility = MeteringUtility(min_value=0, max_value=100, num_pixels=9, height=height)

    def get_vram_usage(self):
        try:
            used = open('/sys/class/drm/card2/device/mem_info_vram_used', 'r')
            total = open('/sys/class/drm/card2/device/mem_info_vram_total', 'r')
        except FileNotFoundError:
            return 0.0  # Return 0 if the files are not found
        lines_used = used.readlines()
        lines_total = total.readlines()
        num_used = int(lines_used[0].strip())
        num_total = int(lines_total[0].strip())
        vram_usage = (num_used / num_total) * 100
        return vram_usage

    def render(self, width):
            vram_usage = self.get_vram_usage()
            metering_image = self.metering_utility.render(width, vram_usage)
            image = Image.new('L', (width, self.height), 0)
            for y in range(self.height):
                for x in range(width):
                    image.putpixel((x, y), metering_image[y][x])
            return image
