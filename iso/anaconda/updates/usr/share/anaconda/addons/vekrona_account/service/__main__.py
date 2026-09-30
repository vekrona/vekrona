from pyanaconda.modules.common import init
init()

from vekrona_account.service.vekrona_account import VekronaAccountService
service = VekronaAccountService()
service.run()
