"""Operator-only fresh tasks and black-box acceptance; never mount this to model."""
import json


def checker(command, cases, suite=None):
    return ('import json, subprocess, pathlib\n'
            + ('subprocess.run(' + repr(suite) + ', check=True, timeout=5)\n'
               + 'for p in sorted(pathlib.Path("/work/tests").rglob("test*.py")):\n'
               + '    if str(p) != "/work/tests/test_cli.py": subprocess.run(["/usr/bin/python3", "-I", str(p)], check=True, timeout=3)\n'
               + 'for p in sorted(pathlib.Path("/work/t").rglob("*.t")):\n'
               + '    subprocess.run(["/usr/bin/perl", str(p)], check=True, timeout=3)\n' if suite else '')
            + 'cases = ' + repr(cases) + '\n'
            + 'for text, expected in cases:\n'
            + '    r = subprocess.run(' + repr(command) + ', input=text, text=True, capture_output=True, timeout=3)\n'
            + '    assert r.returncode == 0, (r.returncode, r.stderr)\n'
            + '    assert json.dumps(json.loads(r.stdout), sort_keys=True) == json.dumps(expected, sort_keys=True), (r.stdout, expected)\n'
            + 'print("trusted cases passed:", len(cases))\n')


def tasks():
    csv_source = '''import json, sys
lines = sys.stdin.read().strip().splitlines()
keys = lines[0].split(',')
print(json.dumps([dict(zip(keys, line.split(','))) for line in lines[1:] if line]))
'''
    inventory_source = '''import json, sys
x = json.load(sys.stdin)
stock = {r['sku']: r['qty'] for r in x['stock']}
for r in x['moves']:
    if r['sku'] in stock: stock[r['sku']] = max(0, stock[r['sku']] + r['qty'])
print(json.dumps(stock))
'''
    perl_source = '''use strict; use warnings; use JSON::PP;
local $/; my $data = JSON::PP->new->utf8->decode(<STDIN>);
my %rows;
for my $row (@{$data->{entries}}) { $rows{lc($row->{name})} = $row->{tags}; }
print JSON::PP->new->utf8->canonical->encode([map { +{name=>$_, tags=>$rows{$_}} } sort keys %rows]);
'''
    specs = [
      ('csv-records', 'csv_cli.py', csv_source, ['/usr/bin/python3', '-I', '/work/csv_cli.py'],
       'Fix this CSV-to-JSON CLI. Read CSV from stdin and emit a JSON array of objects. Support standard CSV quoting, embedded commas/newlines and a UTF-8 BOM. Trim whitespace around header names only; preserve field values. Ignore blank records. Repeated trimmed header names must emit {"error":"duplicate header"}; rows with too few/many fields must emit {"error":"row width"}. No third-party packages. python-csv reference is available.',
       [('name,value\nx,2\n', [{'name':'x','value':'2'}]), ('name,value\n"x,y",2\n', [{'name':'x,y','value':'2'}])],
       [('\ufeff name , value \n"two\nlines"," x "\n\n', [{'name':'two\nlines','value':' x '}]), ('a, a\nx,y\n', {'error':'duplicate header'}), ('a,b\nx\n', {'error':'row width'})],
       [('\nword,count\n"a""b",3\n', [{'word':'a"b','count':'3'}]), ('x,y\n1,2,3\n', {'error':'row width'}), ('\ufeffa,b\n"",0\n', [{'a':'','b':'0'}])]),
      ('inventory-fold', 'inventory.py', inventory_source, ['/usr/bin/python3', '-I', '/work/inventory.py'],
       'Fix this inventory JSON CLI. Input has stock and moves arrays of {sku,qty}. Normalize every SKU by strip then Unicode casefold, sum duplicate stock quantities and every signed movement including previously unseen SKUs, and retain zero/negative balances (do not clamp). Output one JSON object keyed by normalized SKU. Inputs contain integer quantities and nonempty normalized SKUs. No third-party packages.',
       [(json.dumps({'stock':[{'sku':'a','qty':3}], 'moves':[{'sku':'a','qty':-1}]}), {'a':2}), (json.dumps({'stock':[{'sku':'a','qty':3},{'sku':'a','qty':2}], 'moves':[]}), {'a':5})],
       [(json.dumps({'stock':[{'sku':' A ','qty':2}], 'moves':[{'sku':'a','qty':-4},{'sku':'B','qty':0}]}), {'a':-2,'b':0})],
       [(json.dumps({'stock':[{'sku':'Straße','qty':5},{'sku':'STRASSE','qty':-2}], 'moves':[{'sku':' x ','qty':7},{'sku':'X','qty':-7}]}), {'strasse':3,'x':0}), (json.dumps({'stock':[], 'moves':[{'sku':' NEW ','qty':-3}]}), {'new':-3})]),
      ('perl-tag-merge', 'normalize.pl', perl_source, ['/usr/bin/perl', '/work/normalize.pl'],
       'Fix this Perl UTF-8 JSON CLI. Input contains entries array of {name,tags}. Trim leading/trailing whitespace from each name, lowercase it with Unicode lowercase semantics, merge repeated normalized names, trim each tag, discard empty tags, deduplicate exact trimmed tags, and sort tags and records lexically by normalized name. Output [{name,tags}]. Decode/encode UTF-8 correctly. Use core JSON::PP only; perl-json-pp reference is available.',
       [(json.dumps({'entries':[{'name':'B','tags':['x']}]}), [{'name':'b','tags':['x']}]), (json.dumps({'entries':[{'name':' A ','tags':['z','a','z']}]}), [{'name':'a','tags':['a','z']}])],
       [(json.dumps({'entries':[{'name':' A','tags':[' x ','']},{'name':'a ','tags':['y','x']}]}), [{'name':'a','tags':['x','y']}])],
       [(json.dumps({'entries':[{'name':' CAFÉ ','tags':['é',' a ','']},{'name':'café','tags':['é','b']},{'name':' B ','tags':[]}]}), [{'name':'b','tags':[]},{'name':'café','tags':['a','b','é']}]), (json.dumps({'entries':[]}), [])])
    ]
    result = []
    for name, source, code, command, prompt, public, gate, hidden in specs:
        argv = ['/usr/bin/python3', '-I', '/work/tests/test_cli.py']
        files = {source: code, 'tests/test_cli.py': checker(command, public), 'README.md': 'Keep CLI contract and original regressions.\n'}
        task = dict(id=name, branch='burt/'+name, project=name, prompt=prompt, files=files, argv=argv)
        result.append(dict(task=task, editable=[source],
                           checks={'verify.py':checker(command, gate, argv)},
                           hidden={'verify.py':checker(command, hidden)}))
    return result


def solutions():
    return {
      'csv-records': '''import csv, io, json, sys
reader = csv.reader(io.StringIO(sys.stdin.read().removeprefix('\\ufeff')))
try:
    keys = [v.strip() for v in next(row for row in reader if row)]
    if len(keys) != len(set(keys)):
        print(json.dumps({'error':'duplicate header'})); sys.exit(0)
    rows = []
    for values in reader:
        if not values: continue
        if len(values) != len(keys):
            print(json.dumps({'error':'row width'})); sys.exit(0)
        rows.append(dict(zip(keys, values)))
    print(json.dumps(rows))
except StopIteration:
    print('[]')
''',
      'inventory-fold': '''import json, sys
x = json.load(sys.stdin)
out = {}
for r in x['stock'] + x['moves']:
    k = r['sku'].strip().casefold()
    out[k] = out.get(k, 0) + r['qty']
print(json.dumps(out))
''',
      'perl-tag-merge': '''use strict; use warnings; use JSON::PP;
local $/; my $x = JSON::PP->new->utf8->decode(<STDIN>); my %rows;
for my $row (@{$x->{entries}}) {
    my $name = $row->{name}; $name =~ s/^\\s+|\\s+$//g; $name = lc $name;
    $rows{$name} //= {};
    for my $tag (@{$row->{tags}}) { $tag =~ s/^\\s+|\\s+$//g; $rows{$name}{$tag}=1 if length $tag; }
}
print JSON::PP->new->utf8->canonical->encode([map { +{name=>$_, tags=>[sort keys %{$rows{$_}}]} } sort keys %rows]);
'''
    }
