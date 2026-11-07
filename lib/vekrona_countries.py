"""Country codes and names for vekrona-vpn: the ISO 3166-1 table, the names people type, and the lookups on them.

The table and the lookups are ported from yolobox-network's egress.py."""
import difflib
import re
from typing import Dict, Sequence, Tuple


class CountryError(ValueError):
    """What was typed names no single country, or none that has an exit."""


# One "<alpha-2> <name>" per line (ISO 3166-1, in the names people type).
ISO_COUNTRIES = """
ad Andorra
ae United Arab Emirates
af Afghanistan
ag Antigua and Barbuda
ai Anguilla
al Albania
am Armenia
ao Angola
aq Antarctica
ar Argentina
as American Samoa
at Austria
au Australia
aw Aruba
ax Aland Islands
az Azerbaijan
ba Bosnia and Herzegovina
bb Barbados
bd Bangladesh
be Belgium
bf Burkina Faso
bg Bulgaria
bh Bahrain
bi Burundi
bj Benin
bl Saint Barthelemy
bm Bermuda
bn Brunei
bo Bolivia
bq Bonaire, Sint Eustatius and Saba
br Brazil
bs Bahamas
bt Bhutan
bv Bouvet Island
bw Botswana
by Belarus
bz Belize
ca Canada
cc Cocos Islands
cd Democratic Republic of the Congo
cf Central African Republic
cg Congo
ch Switzerland
ci Ivory Coast
ck Cook Islands
cl Chile
cm Cameroon
cn China
co Colombia
cr Costa Rica
cu Cuba
cv Cape Verde
cw Curacao
cx Christmas Island
cy Cyprus
cz Czechia
de Germany
dj Djibouti
dk Denmark
dm Dominica
do Dominican Republic
dz Algeria
ec Ecuador
ee Estonia
eg Egypt
eh Western Sahara
er Eritrea
es Spain
et Ethiopia
fi Finland
fj Fiji
fk Falkland Islands
fm Micronesia
fo Faroe Islands
fr France
ga Gabon
gb United Kingdom
gd Grenada
ge Georgia
gf French Guiana
gg Guernsey
gh Ghana
gi Gibraltar
gl Greenland
gm Gambia
gn Guinea
gp Guadeloupe
gq Equatorial Guinea
gr Greece
gs South Georgia and the South Sandwich Islands
gt Guatemala
gu Guam
gw Guinea-Bissau
gy Guyana
hk Hong Kong
hm Heard Island and McDonald Islands
hn Honduras
hr Croatia
ht Haiti
hu Hungary
id Indonesia
ie Ireland
il Israel
im Isle of Man
in India
io British Indian Ocean Territory
iq Iraq
ir Iran
is Iceland
it Italy
je Jersey
jm Jamaica
jo Jordan
jp Japan
ke Kenya
kg Kyrgyzstan
kh Cambodia
ki Kiribati
km Comoros
kn Saint Kitts and Nevis
kp North Korea
kr South Korea
kw Kuwait
ky Cayman Islands
kz Kazakhstan
la Laos
lb Lebanon
lc Saint Lucia
li Liechtenstein
lk Sri Lanka
lr Liberia
ls Lesotho
lt Lithuania
lu Luxembourg
lv Latvia
ly Libya
ma Morocco
mc Monaco
md Moldova
me Montenegro
mf Saint Martin
mg Madagascar
mh Marshall Islands
mk North Macedonia
ml Mali
mm Myanmar
mn Mongolia
mo Macao
mp Northern Mariana Islands
mq Martinique
mr Mauritania
ms Montserrat
mt Malta
mu Mauritius
mv Maldives
mw Malawi
mx Mexico
my Malaysia
mz Mozambique
na Namibia
nc New Caledonia
ne Niger
nf Norfolk Island
ng Nigeria
ni Nicaragua
nl Netherlands
no Norway
np Nepal
nr Nauru
nu Niue
nz New Zealand
om Oman
pa Panama
pe Peru
pf French Polynesia
pg Papua New Guinea
ph Philippines
pk Pakistan
pl Poland
pm Saint Pierre and Miquelon
pn Pitcairn
pr Puerto Rico
ps Palestine
pt Portugal
pw Palau
py Paraguay
qa Qatar
re Reunion
ro Romania
rs Serbia
ru Russia
rw Rwanda
sa Saudi Arabia
sb Solomon Islands
sc Seychelles
sd Sudan
se Sweden
sg Singapore
sh Saint Helena
si Slovenia
sj Svalbard and Jan Mayen
sk Slovakia
sl Sierra Leone
sm San Marino
sn Senegal
so Somalia
sr Suriname
ss South Sudan
st Sao Tome and Principe
sv El Salvador
sx Sint Maarten
sy Syria
sz Eswatini
tc Turks and Caicos Islands
td Chad
tf French Southern Territories
tg Togo
th Thailand
tj Tajikistan
tk Tokelau
tl Timor-Leste
tm Turkmenistan
tn Tunisia
to Tonga
tr Turkey
tt Trinidad and Tobago
tv Tuvalu
tw Taiwan
tz Tanzania
ua Ukraine
ug Uganda
um US Minor Outlying Islands
us United States
uy Uruguay
uz Uzbekistan
va Vatican City
vc Saint Vincent and the Grenadines
ve Venezuela
vg British Virgin Islands
vi US Virgin Islands
vn Vietnam
vu Vanuatu
wf Wallis and Futuna
ws Samoa
xk Kosovo
ye Yemen
yt Mayotte
za South Africa
zm Zambia
zw Zimbabwe
"""

# Other names people type, and the names Mullvad's own list uses.
COUNTRY_ALIASES = {
    "usa": "us",
    "america": "us",
    "united states of america": "us",
    "states of america": "us",
    "uk": "gb",
    "great britain": "gb",
    "britain": "gb",
    "england": "gb",
    "holland": "nl",
    "the netherlands": "nl",
    "uae": "ae",
    "korea": "kr",
    "czech republic": "cz",
    "russian federation": "ru",
    "viet nam": "vn",
    "turkiye": "tr",
    "cote d'ivoire": "ci",
    "burma": "mm",
    "macedonia": "mk",
    "swaziland": "sz",
    "drc": "cd",
    "republic of the congo": "cg",
}

ISO_NAMES: Dict[str, str] = dict(line.split(" ", 1) for line in ISO_COUNTRIES.strip().splitlines())

# The file name of a configuration that says nothing about its country.
UNKNOWN_COUNTRY = "??"
UNKNOWN_COUNTRY_NAME = "Unknown"


# resolve_country: how many spellings difflib offers, how alike one must be to count as the person's meaning, and how alike to be
# worth naming as "closest" in the error; and how many candidates an error names.
FUZZY_MATCHES = 5
FUZZY_MATCH_CUTOFF = 0.8
FUZZY_CLOSEST_CUTOFF = 0.5
CANDIDATES_NAMED = 5


def normalize(text: str) -> str:
    return " ".join(text.casefold().split())


def display_name(code: str, provider_names: Dict[str, str]) -> str:
    return ISO_NAMES.get(code) or provider_names.get(code) or code.upper()


def _candidates(codes: Sequence[str], provider_names: Dict[str, str]) -> str:
    return ", ".join("%s (%s)" % (display_name(code, provider_names), code.upper()) for code in sorted(codes)[:CANDIDATES_NAMED])


def _spellings(available: Dict[str, str]) -> Dict[str, str]:
    """Every spelling of every available country: spelling -> code."""
    spellings: Dict[str, str] = {}
    for code, name in available.items():
        spellings[normalize(name)] = code
        if code in ISO_NAMES:
            spellings[normalize(ISO_NAMES[code])] = code
    for alias, code in COUNTRY_ALIASES.items():
        if code in available:
            spellings[alias] = code
    return spellings


def resolve_country(query: str, provider_names: Dict[str, str]) -> Tuple[str, bool]:
    """The one country code of `provider_names` (code -> name, the countries that have exits now) that `query` means.

    Returns (code, exact): `exact` is false when the match was a guess that the caller should echo. Raises CountryError,
    naming the closest candidates, when there is no single clear winner."""
    query_norm = normalize(query)
    if not query_norm:
        raise CountryError("the country is empty")
    available = {code: display_name(code, provider_names) for code in provider_names}
    if query_norm in available:
        return query_norm, True
    spellings = _spellings(provider_names)
    if query_norm in spellings:
        return spellings[query_norm], False
    known_anywhere = {normalize(name): code for code, name in ISO_NAMES.items()}
    known_anywhere.update(COUNTRY_ALIASES)
    if query_norm in known_anywhere or query_norm in ISO_NAMES:
        code = known_anywhere.get(query_norm, query_norm)
        raise CountryError("%s (%s) has no exits right now" % (display_name(code, provider_names), code.upper()))
    if len(query_norm) >= 3:
        by_prefix = {code for spelling, code in spellings.items() if spelling.startswith(query_norm)}
        if len(by_prefix) == 1:
            return by_prefix.pop(), False
        if by_prefix:
            raise CountryError("%r is ambiguous: %s" % (query, _candidates(list(by_prefix), provider_names)))
    close = difflib.get_close_matches(query_norm, list(spellings), n=FUZZY_MATCHES, cutoff=FUZZY_MATCH_CUTOFF)
    winners = {spellings[spelling] for spelling in close}
    if len(winners) == 1:
        return winners.pop(), False
    if winners:
        raise CountryError("%r is ambiguous: %s" % (query, _candidates(list(winners), provider_names)))
    near = {spellings[spelling] for spelling in difflib.get_close_matches(query_norm, list(spellings), n=FUZZY_MATCHES, cutoff=FUZZY_CLOSEST_CUTOFF)}
    raise CountryError("no country matches %r. %s: %s" % (
        query, "Closest" if near else "Available", _candidates(list(near or available), provider_names)))


def country_in_file_name(file_name: str) -> str:
    """The upper-case code of the first two-letter token of the file name that is an ISO country ("NL-792.conf",
    "nl-ams-wg-001.conf"), else UNKNOWN_COUNTRY. Tokens are the runs of ASCII letters, so "nlams" is no token."""
    stem = file_name.rsplit(".", 1)[0]
    for token in re.findall(r"[A-Za-z]+", stem):
        if len(token) == 2 and token.lower() in ISO_NAMES:
            return token.upper()
    return UNKNOWN_COUNTRY
