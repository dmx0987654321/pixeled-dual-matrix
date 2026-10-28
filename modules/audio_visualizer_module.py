import time

from modules.module_base import ModuleBase
from utils.sound_visualizer import sound_visualizer
from utils.ticker_line import TickerLine


class AudioVisualizerModule(ModuleBase):
    """The sound visualizer, resting along the panel's title row."""

    def __init__(self, height=5, scroll_speed=24.0):
        super().__init__(height or 5)
        self._line = TickerLine(9, float(scroll_speed))
        self._visualizer = sound_visualizer()
        self._vis_at = None
        self._clock = None

    def set_scroll_speed(self, px_per_second):
        self._line.text_speed = float(px_per_second)

    def hand_over(self, width):
        """Give up the title row so an overlay can continue its current line."""
        self._line.width = width
        handback, _ = self._line.give(0.0)
        self._vis_at = None
        return handback['pieces'], handback['x'], handback['speed']

    def take_back(self, pieces, x, width, speed, accel, dt):
        """Resume scrolling after an overlay has used the title row."""
        self._line.width = width
        self._line.take_back(pieces, x, speed, dt)
        self._vis_at = self._line.rest(self._visualizer)
        self._clock = time.monotonic() - dt

    def render(self, width):
        now = time.monotonic()
        dt = 0.0 if self._clock is None else min(max(now - self._clock, 0.0), 0.25)
        self._clock = now
        self._line.width = width
        image = super().render(width)
        if self._vis_at is None:
            self._vis_at = self._line.rest(self._visualizer)
        self._line.move(dt, self._vis_at + width, 0.0)
        self._line.draw(image, [(self._visualizer, self._vis_at)])
        return image
