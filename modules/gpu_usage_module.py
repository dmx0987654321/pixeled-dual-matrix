import time

import numpy as np
from PIL import Image

from modules.module_base import ModuleBase
from utils.metering_utility import MeteringUtility

class GpuUsageModule(ModuleBase):
    def __init__(self, height=1, sample_interval=0.05, glow_half_life=0.08):
        super().__init__(height)  #module height
        self.metering_utility = MeteringUtility(min_value=0, max_value=100, num_pixels=9, height=height)
        self.previous_idle = []
        self.previous_total = []
        self.num_cores = self.get_num_cores()
        self.sample_interval = sample_interval   # seconds between /proc/stat reads
        self.glow_half_life = glow_half_life     # seconds for an unlit pixel to halve
        self._sampled_at = None
        self._levels = None     # the meter as last sampled, float brightness
        self._glow = None       # what is on the panel, decaying toward _levels
        self._last_render = None

    def get_num_cores(self):
        with open('/proc/stat', 'r') as f:
            lines = f.readlines()
        core_count = 0
        for line in lines:
            if line.startswith('cpu') and not line.startswith('cpu '):
                core_count += 1
        return core_count

    def get_gpu_usage_per_thread(self):
        with open('/proc/stat', 'r') as f:
            lines = f.readlines()

        current_idle = []
        current_total = []

        for line in lines:
            if line.startswith('cpu '):
                continue  # Skip the aggregate line
            if line.startswith('cpu'):
                fields = [float(column) for column in line.strip().split()[1:]]
                user, nice, system, idle, iowait, irq, softirq, steal, guest, guest_nice = fields[:10]

                idle_all_time = idle + iowait
                non_idle_all_time = user + nice + system + irq + softirq + steal
                total_time = idle_all_time + non_idle_all_time

                current_idle.append(idle_all_time)
                current_total.append(total_time)

        if not self.previous_idle or not self.previous_total:
            self.previous_idle = current_idle
            self.previous_total = current_total

        usage_per_thread = []
        for i in range(len(current_idle)):
            total_d = current_total[i] - self.previous_total[i]
            idle_d = current_idle[i] - self.previous_idle[i]

            if total_d == 0:
                usage_per_thread.append(0.0)
            else:
                usage_per_thread.append(100 * (total_d - idle_d) / total_d)

        self.previous_idle = current_idle
        self.previous_total = current_total

        return usage_per_thread

    def _meter(self, width):
        """The meter for a fresh sample, as float brightness."""
        usage_per_thread = self.get_gpu_usage_per_thread()
        num_threads = len(usage_per_thread)
        base_threads_per_pixel = num_threads // self.height
        extra_threads = num_threads % self.height

        pixel_usages = []
        start_index = 0

        for i in range(self.height):
            threads_in_this_pixel = base_threads_per_pixel + (1 if i < extra_threads else 0)
            end_index = start_index + threads_in_this_pixel
            average_usage = sum(usage_per_thread[start_index:end_index]) / threads_in_this_pixel
            pixel_usages.append(average_usage)
            start_index = end_index

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