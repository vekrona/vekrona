from pyanaconda.modules.common import init
init()

from vekrona_signin.service.vekrona_signin import VekronaSignInService
service = VekronaSignInService()
service.run()
