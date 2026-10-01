import ast
import importlib
import importlib.util
import unittest
import xml.etree.ElementTree as ElementTree

import _paths

SPOKES = {
    "VekronaAccountSpoke": _paths.ADDONS_DIR / "vekrona_account/gui/spokes/vekrona_account.py",
    "VekronaSignInSpoke": _paths.ADDONS_DIR / "vekrona_signin/gui/spokes/vekrona_signin.py",
}
INHERITED_HANDLERS = {"on_back_clicked"}
MODULES_MISSING_ON_THIS_HOST = ("pyanaconda.ui.gui", "gi")


def spoke_class(class_name):
    tree = ast.parse(SPOKES[class_name].read_text())
    return tree, next(node for node in tree.body if isinstance(node, ast.ClassDef) and node.name == class_name)


def class_constant(class_node, name):
    for node in class_node.body:
        if isinstance(node, ast.Assign) and any(target.id == name for target in node.targets):
            value = node.value
            if isinstance(value, ast.Call):
                value = value.args[0]
            return ast.literal_eval(value)
    raise AssertionError(f"{class_node.name}.{name} is not defined")


def glade_of(class_name):
    _, class_node = spoke_class(class_name)
    return ElementTree.parse(SPOKES[class_name].parent / class_constant(class_node, "uiFile")).getroot()


class SpokeMatchesItsGladeTest(unittest.TestCase):
    def test_every_glade_signal_handler_is_a_spoke_method(self):
        for class_name in SPOKES:
            with self.subTest(class_name):
                _, class_node = spoke_class(class_name)
                methods = {node.name for node in class_node.body if isinstance(node, ast.FunctionDef)}
                handlers = {signal.get("handler") for signal in glade_of(class_name).iter("signal")}
                self.assertEqual(handlers - methods - INHERITED_HANDLERS, set())

    def test_every_widget_the_spoke_asks_for_is_in_the_glade(self):
        for class_name in SPOKES:
            with self.subTest(class_name):
                tree, _ = spoke_class(class_name)
                ids = {obj.get("id") for obj in glade_of(class_name).iter("object")}
                requested = {
                    node.args[0].value
                    for node in ast.walk(tree)
                    if isinstance(node, ast.Call)
                    and isinstance(node.func, ast.Attribute)
                    and node.func.attr == "get_object"
                }
                self.assertTrue(requested)
                self.assertEqual(requested - ids, set())

    def test_main_widget_is_in_the_glade(self):
        for class_name in SPOKES:
            with self.subTest(class_name):
                _, class_node = spoke_class(class_name)
                ids = {obj.get("id") for obj in glade_of(class_name).iter("object")}
                self.assertIn(class_constant(class_node, "mainWidgetName"), ids)
                self.assertLessEqual(set(class_constant(class_node, "builderObjects")), ids)

    def test_content_sits_in_the_spoke_window_action_area(self):
        for class_name in SPOKES:
            with self.subTest(class_name):
                root = glade_of(class_name)
                action_area = next(
                    child.find("object")
                    for child in root.iter("child")
                    if child.get("internal-child") == "action_area"
                )
                content = {obj.get("id") for obj in action_area.iter("object")}
                self.assertTrue({"mainGrid", "mainBox"} & content)


class SpokeImportsExistTest(unittest.TestCase):
    def test_every_name_imported_from_a_module_available_here_exists(self):
        for class_name, path in SPOKES.items():
            tree, _ = spoke_class(class_name)
            for node in ast.walk(tree):
                if not isinstance(node, ast.ImportFrom) or node.module.startswith(MODULES_MISSING_ON_THIS_HOST):
                    continue
                module = importlib.import_module(node.module)
                for alias in node.names:
                    with self.subTest(spoke=class_name, name=f"{node.module}.{alias.name}"):
                        self.assertTrue(
                            hasattr(module, alias.name) or importlib.util.find_spec(f"{node.module}.{alias.name}")
                        )


class HubOrderTest(unittest.TestCase):
    def test_sign_in_follows_the_account_in_the_same_category(self):
        _, account = spoke_class("VekronaAccountSpoke")
        _, signin = spoke_class("VekronaSignInSpoke")
        account_title = class_constant(account, "title")
        signin_title = class_constant(signin, "title")
        self.assertEqual(sorted([signin_title, account_title]), [account_title, signin_title])
        categories = {
            next(ast.unparse(node.value) for node in spoke.body
                 if isinstance(node, ast.Assign) and node.targets[0].id == "category")
            for spoke in (account, signin)
        }
        self.assertEqual(categories, {"VekronaCategory"})

    def test_sign_in_is_mandatory(self):
        _, signin = spoke_class("VekronaSignInSpoke")
        mandatory = next(node for node in signin.body
                         if isinstance(node, ast.FunctionDef) and node.name == "mandatory")
        self.assertEqual(ast.unparse(mandatory.body[-1]), "return True")


if __name__ == "__main__":
    unittest.main()
