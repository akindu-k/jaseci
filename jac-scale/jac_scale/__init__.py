from jaclang.pycore.runtime import plugin_manager

from .plugin import JacScalePlugin

plugin_manager.register(JacScalePlugin())

__all__ = []
