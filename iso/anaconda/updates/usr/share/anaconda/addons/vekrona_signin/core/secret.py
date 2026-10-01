__all__ = ["Secret"]


class Secret:
    __slots__ = ("_text",)

    def __init__(self, text):
        self._text = text

    def reveal(self):
        return self._text

    def __repr__(self):
        return "<secret>"

    __str__ = __repr__
