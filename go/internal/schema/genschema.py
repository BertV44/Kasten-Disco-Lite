#!/usr/bin/env python3
"""Derive Go structs from a real KDL discovery JSON.

Reads the report JSON, infers a type tree (merging keys across every element of
each array so optional fields are detected), and emits one named struct per
distinct object path. Field order follows the JSON, which follows KDL.sh's
emission order.
"""
import json
import sys
from collections import OrderedDict

# ---------------------------------------------------------------- naming ----

ACRONYMS = {
    "id": "ID", "ids": "IDs", "url": "URL", "urls": "URLs", "uri": "URI",
    "api": "API", "tls": "TLS", "rbac": "RBAC", "rpo": "RPO", "rp": "RP",
    "vm": "VM", "vms": "VMs", "pvc": "PVC", "pvcs": "PVCs", "kms": "KMS",
    "dr": "DR", "csi": "CSI", "fips": "FIPS", "gvb": "GVB", "ca": "CA",
    "sa": "SA", "sas": "SAs", "cpu": "CPU", "crd": "CRD", "crds": "CRDs",
    "crb": "CRB", "cr": "CR", "ns": "NS", "os": "OS", "io": "IO",
    "json": "JSON", "html": "HTML", "yaml": "YAML", "k10": "K10",
    "kdl": "KDL", "kdr": "KDR", "vbr": "VBR", "gib": "GiB", "mib": "MiB",
    "tib": "TiB", "netpol": "NetPol", "http": "HTTP", "ttl": "TTL",
    "ok": "OK", "bp": "BP", "mc": "MC", "vsc": "VSC", "vscs": "VSCs",
}

IRREGULAR = {
    "licenses": "license", "classes": "class", "policies": "policy",
    "properties": "property", "entries": "entry", "statuses": "status",
    "addresses": "address", "indices": "index", "matches": "match",
}


def split_words(key):
    """Split a JSON key (camelCase, snake_case, kebab-case) into lowercase words."""
    out, cur = [], ""
    for ch in key.replace("_", "-").replace(".", "-").replace("/", "-"):
        if ch == "-":
            if cur:
                out.append(cur)
                cur = ""
            continue
        if ch.isupper() and cur and not cur[-1].isupper():
            out.append(cur)
            cur = ch
        elif ch.isdigit() and cur and not cur[-1].isdigit():
            out.append(cur)
            cur = ch
        else:
            cur += ch
    if cur:
        out.append(cur)
    return [w.lower() for w in out if w]


def go_name(key):
    """JSON key -> exported Go identifier, with acronyms in canonical case."""
    words = split_words(key)
    parts = []
    for w in words:
        parts.append(ACRONYMS.get(w, w[:1].upper() + w[1:]))
    name = "".join(parts)
    if not name:
        return "Field"
    if name[0].isdigit():
        name = "N" + name
    return name


def singular(key):
    """Singularize a JSON array key, so its element struct reads naturally."""
    low = key.lower()
    if low in IRREGULAR:
        return IRREGULAR[low]
    if low.endswith("ies"):
        return key[:-3] + "y"
    for suf in ("sses", "xes", "ches", "shes"):
        if low.endswith(suf):
            return key[:-2]
    if low.endswith("s") and not low.endswith("ss"):
        return key[:-1]
    return key + "Item"


def combine(parent, field):
    """Append field to parent, collapsing an overlapping tail.

    Avoids stutter like LicenseLicense or PolicyRunStatsLastRunLastRun: when the
    parent name already ends with the field name, the element gets an -Entry
    suffix instead of repeating the segment.
    """
    if not parent:
        return field
    if parent == field or parent.endswith(field):
        return parent + "Entry"
    return parent + field


# ------------------------------------------------------------- inference ----

class Node:
    """Inferred type for one JSON position, accumulated over all samples."""

    def __init__(self):
        self.kinds = set()        # observed JSON kinds
        self.fields = OrderedDict()  # object: key -> Node
        self.field_seen = {}      # object: key -> how many object samples had it
        self.samples = 0          # how many object samples reached here
        self.elem = None          # array: element Node
        self.saw_int = False
        self.saw_float = False


def observe(node, value):
    if value is None:
        node.kinds.add("null")
    elif isinstance(value, bool):
        node.kinds.add("bool")
    elif isinstance(value, int):
        node.kinds.add("number")
        node.saw_int = True
    elif isinstance(value, float):
        node.kinds.add("number")
        node.saw_float = True
    elif isinstance(value, str):
        node.kinds.add("string")
    elif isinstance(value, list):
        node.kinds.add("array")
        if node.elem is None:
            node.elem = Node()
        for item in value:
            observe(node.elem, item)
    elif isinstance(value, dict):
        node.kinds.add("object")
        node.samples += 1
        for k, v in value.items():
            if k not in node.fields:
                node.fields[k] = Node()
                node.field_seen[k] = 0
            node.field_seen[k] += 1
            observe(node.fields[k], v)
    return node


# ---------------------------------------------------------------- emit ------

def is_map_like(node):
    """Is this object keyed by arbitrary data rather than a fixed schema?

    A key containing "/" is the giveaway: Kubernetes label and annotation keys
    are namespaced that way, and no such key can become a Go identifier.
    """
    return any("/" in k for k in node.fields)


def map_value_type(node):
    """Go value type for a map-like object, merged over every observed value."""
    kinds, saw_float = set(), False
    for child in node.fields.values():
        kinds |= child.kinds - {"null"}
        saw_float = saw_float or child.saw_float
    if kinds == {"string"}:
        return "string"
    if kinds == {"bool"}:
        return "bool"
    if kinds == {"number"}:
        return "float64" if saw_float else "int"
    return "json.RawMessage"


class Emitter:
    def __init__(self):
        self.structs = []        # (name, [(goField, goType, jsonTag, comment)])
        self.used_names = set()

    def unique(self, base):
        name = base
        n = 2
        while name in self.used_names:
            name = "%s%d" % (base, n)
            n += 1
        self.used_names.add(name)
        return name

    def type_of(self, node, parent, key):
        """Return the Go type string for node, registering nested structs.

        parent is the enclosing struct name ("" directly under Report, so the
        top-level sections get short names), key the JSON key at this position.
        """
        kinds = node.kinds - {"null"}
        nullable = "null" in node.kinds

        if not kinds:
            # Only ever null in this sample: type unknown.
            return "json.RawMessage", "always null in the source sample - type unverified"

        if len(kinds) > 1:
            return "json.RawMessage", "mixed types in source (%s)" % ",".join(sorted(kinds))

        kind = next(iter(kinds))

        if kind == "bool":
            return ("*bool" if nullable else "bool"), None
        if kind == "string":
            return ("*string" if nullable else "string"), None
        if kind == "number":
            base = "float64" if node.saw_float else "int"
            note = None
            if base == "int":
                note = None
            return ("*" + base if nullable else base), note
        if kind == "array":
            if node.elem is None or not (node.elem.kinds - {"null"}):
                return "[]json.RawMessage", "empty array in the source sample - element type unverified"
            inner, note = self.type_of(node.elem, parent, singular(key))
            return "[]" + inner, note
        if kind == "object":
            if is_map_like(node):
                # Kubernetes labels and annotations are keyed by arbitrary data.
                # Turning the keys observed on one cluster into struct fields
                # would (a) not compile, since label keys contain "/", and (b) be
                # wrong: another cluster carries different keys entirely.
                return "map[string]%s" % map_value_type(node), \
                    "label-style keys: arbitrary data, modelled as a map"
            name = self.emit_struct(node, combine(parent, go_name(key)))
            return ("*" + name if nullable else name), None
        return "json.RawMessage", "unhandled kind %s" % kind

    def emit_struct(self, node, base_name):
        name = self.unique(base_name)
        # Sections directly under Report are named after themselves, so nested
        # types read as License/LicenseNodeConsumption rather than ReportLicense.
        child_parent = "" if name == "Report" else name
        fields = []
        for key, child in node.fields.items():
            field = go_name(key)
            gotype, note = self.type_of(child, child_parent, key)
            optional = node.field_seen.get(key, 0) < node.samples
            tag = key + (",omitempty" if optional else "")
            comment = note
            if optional and not comment:
                comment = "absent from %d/%d samples" % (
                    node.samples - node.field_seen[key], node.samples)
            fields.append((field, gotype, tag, comment))
        self.structs.append((name, fields))
        return name

    def render(self, root_name, header):
        out = [header]
        # Root struct first, then nested in declaration order.
        by_name = {n: f for n, f in self.structs}
        order = [root_name] + [n for n, _ in self.structs if n != root_name]
        for name in order:
            if name not in by_name:
                continue
            fields = by_name[name]
            out.append("// %s mirrors the corresponding object in the KDL report JSON." % name)
            out.append("type %s struct {" % name)
            width_f = max([len(f[0]) for f in fields] + [1])
            width_t = max([len(f[1]) for f in fields] + [1])
            for field, gotype, tag, comment in fields:
                line = "\t%-*s %-*s `json:\"%s\"`" % (width_f, field, width_t, gotype, tag)
                if comment:
                    line += " // " + comment
                out.append(line)
            out.append("}")
            out.append("")
        return "\n".join(out)


HEADER = '''// Code generated from a real KDL discovery report, then hand-refined. DO NOT
// regenerate blindly: several types were widened by hand where the source
// sample was not representative (see the notes below and schema_notes.md).
//
// Source sample: discovery-dev2.0-cluster-anon.json (KDL %s)
// Types marked "unverified" were inferred from a single cluster and need a
// second sample to confirm.

package schema

import "encoding/json"
'''


def main():
    src = sys.argv[1]
    with open(src) as fh:
        doc = json.load(fh, object_pairs_hook=OrderedDict)

    root = observe(Node(), doc)
    em = Emitter()
    root_name = em.emit_struct(root, "Report")
    version = doc.get("kdlVersion", "unknown")
    sys.stdout.write(em.render(root_name, HEADER % version))
    sys.stderr.write("structs: %d\n" % len(em.structs))


if __name__ == "__main__":
    main()
