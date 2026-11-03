from modules.module_base import ModuleBase
from utils.metering_utility import MeteringUtility
from PIL import Image
import numpy as np
import time, struct

class GpuUsageModule(ModuleBase):
    def __init__(self, height=1, sample_interval=0.05, glow_half_life=0.08):
        super().__init__(height)  # module height
        self.metering_utility = MeteringUtility(min_value=0, max_value=100, num_pixels=9, height=height)
        self.previous_idle = []
        self.previous_total = []
        self.sample_interval = sample_interval   # seconds between usage reads
        self.glow_half_life = glow_half_life     # seconds for an unlit pixel to halve
        self._sampled_at = None
        self._levels = None     # the meter as last sampled, float brightness
        self._glow = None       # what is on the panel, decaying toward _levels
        self._last_render = None
    
    def get_gpu_usage(self):
        percent_used_per_metric = []

        # Overall usage
        try:
            f = open('/sys/class/drm/card2/device/gpu_busy_percent', 'r')
        except FileNotFoundError:
            return 0.0 
        usage = f.readlines()
        percent_used_per_metric.append(int(usage[0].strip()))

        # Independent usage for each GPU engine
        binary_data = []
        with open('/sys/class/drm/card2/device/gpu_metrics', 'rb') as f:
            while True:
                chunk = f.read(4)
                if not chunk or len(chunk) < 4:
                    break
                val1, val2 = struct.unpack('<HH', chunk)
                binary_data.append((val1, val2))

        return percent_used_per_metric

    def _meter(self, width):
        percent_used = self.get_gpu_usage()
        pixel_usages = [percent_used] * width 
        return np.array(self.metering_utility.render(width, pixel_usages), dtype=np.float64)

    def render(self, width):
            now = time.monotonic()
            if (self._sampled_at is None
                    or not 0.0 <= now - self._sampled_at < self.sample_interval):
                self._sampled_at = now
                self._levels = self._meter(width)
    
            # Clamped like the other animations, so a stall fades the glow out
            # rather than holding it, and a clock stepping back holds for a frame.
            dt = 0.0 if self._last_render is None else min(max(now - self._last_render, 0.0), 0.25)
            self._last_render = now
    
            if self._glow is None or self._glow.shape != self._levels.shape:
                self._glow = self._levels.copy()
            else:
                fade = 0.5 ** (dt / self.glow_half_life)
                self._glow = np.maximum(self._levels, self._glow * fade)
    
            return Image.fromarray(np.rint(self._glow).astype(np.uint8), 'L')