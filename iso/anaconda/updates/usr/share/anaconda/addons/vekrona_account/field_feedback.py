__all__ = ["FieldFeedback"]


class FieldFeedback:
    def __init__(self):
        self._edited = set()
        self._leave_attempted = False

    def edited(self, field):
        self._edited.add(field)

    def leave_attempted(self):
        self._leave_attempted = True

    def reset(self):
        self._edited.clear()
        self._leave_attempted = False

    def visible_errors(self, errors):
        return {
            field: error if self._leave_attempted or field in self._edited else None
            for field, error in errors.items()
        }
