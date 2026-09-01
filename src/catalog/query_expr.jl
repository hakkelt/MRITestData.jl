# String-based boolean query language: a compound-condition front end for `query`
# (see `query.jl`), used by the interactive browser's `/` overlay and callable directly
# from the REPL as `query("...")`. Pure parsing/evaluation, no TTY dependency.
#
#   or_expr  := and_expr (OR and_expr)*
#   and_expr := atom (AND atom)*
#   atom     := '(' or_expr ')' | IDENT OP value
#   OP       := '=' | '!=' | '<' | '<=' | '>' | '>='
#   value    := 'quoted string' | "quoted string" | number | bareword
#
# `AND`/`OR` are case-insensitive keywords; `AND` binds tighter than `OR`. A bareword or
# quoted string containing `*` is a case-insensitive glob (`*` → `.*`, anchored) for
# `=`/`!=`; without a `*` it's an exact case-insensitive string compare. `<`/`<=`/`>`/`>=`
# compare numerically and never match a non-numeric or missing field (mirrors Tachikoma's
# own `:numeric` column-filter semantics — see `apply_filter` and the "R" column).

# ── AST ──────────────────────────────────────────────────────────────────────

abstract type QueryNode end

"""
    QCmp(field, op, value)

One `field OP value` comparison in a parsed query expression (see [`parse_query_expr`](@ref)).
`op` is one of `:eq`, `:neq`, `:lt`, `:lte`, `:gt`, `:gte`; `value` is a `String`, `Float64`,
or `Bool` literal.
"""
struct QCmp <: QueryNode
    field::String
    op::Symbol
    value::Any
end

struct QAnd <: QueryNode
    l::QueryNode
    r::QueryNode
end

struct QOr <: QueryNode
    l::QueryNode
    r::QueryNode
end

"""
    QueryParseError(msg, pos)

Thrown by [`parse_query_expr`](@ref) on malformed input; `pos` is the byte offset into the
query string where the problem was found. The browser's query overlay catches this and
shows `msg` instead of applying a broken filter.
"""
struct QueryParseError <: Exception
    msg::String
    pos::Int
end

Base.showerror(io::IO, e::QueryParseError) = print(io, "query syntax error at byte $(e.pos): $(e.msg)")

# ── Tokenizer ──────────────────────────────────────────────────────────────

struct _QToken
    kind::Symbol   # :lparen, :rparen, :and, :or, :op, :string, :number, :bareword, :eof
    text::String
    pos::Int
end

const _QOP_MAP = Dict("=" => :eq, "!=" => :neq, "<" => :lt, "<=" => :lte, ">" => :gt, ">=" => :gte)
const _QWORD_STOP = "()'\"=<>!"

function _tokenize(s::AbstractString)
    tokens = _QToken[]
    n = lastindex(s)
    i = firstindex(s)
    while i <= n
        c = s[i]
        if isspace(c)
            i = nextind(s, i)
        elseif c == '('
            push!(tokens, _QToken(:lparen, "(", i))
            i = nextind(s, i)
        elseif c == ')'
            push!(tokens, _QToken(:rparen, ")", i))
            i = nextind(s, i)
        elseif c == '\'' || c == '"'
            start = i
            j = nextind(s, i)
            buf = IOBuffer()
            closed = false
            while j <= n
                if s[j] == c
                    closed = true
                    j = nextind(s, j)
                    break
                end
                write(buf, s[j])
                j = nextind(s, j)
            end
            closed || throw(QueryParseError("unterminated string literal", start))
            push!(tokens, _QToken(:string, String(take!(buf)), start))
            i = j
        elseif c == '!' && i < n && s[nextind(s, i)] == '='
            push!(tokens, _QToken(:op, "!=", i))
            i = nextind(s, nextind(s, i))
        elseif c == '<' || c == '>'
            j = nextind(s, i)
            if j <= n && s[j] == '='
                push!(tokens, _QToken(:op, string(c, '='), i))
                i = nextind(s, j)
            else
                push!(tokens, _QToken(:op, string(c), i))
                i = j
            end
        elseif c == '='
            push!(tokens, _QToken(:op, "=", i))
            i = nextind(s, i)
        else
            start = i
            j = i
            while j <= n && !isspace(s[j]) && !(s[j] in _QWORD_STOP)
                j = nextind(s, j)
            end
            word = s[start:prevind(s, j)]
            isempty(word) && throw(QueryParseError("unexpected character $(repr(c))", i))
            kind = if uppercase(word) == "AND"
                :and
            elseif uppercase(word) == "OR"
                :or
            elseif occursin(r"^-?\d+(\.\d+)?$", word)
                :number
            else
                :bareword
            end
            push!(tokens, _QToken(kind, word, start))
            i = j
        end
    end
    push!(tokens, _QToken(:eof, "", n + 1))
    return tokens
end

# ── Parser (recursive descent) ────────────────────────────────────────────────

mutable struct _QParser
    tokens::Vector{_QToken}
    pos::Int
end

_peek(p::_QParser) = p.tokens[p.pos]
function _advance!(p::_QParser)
    t = p.tokens[p.pos]
    p.pos += 1
    return t
end

"""
    parse_query_expr(text::AbstractString) -> QueryNode

Parse a string query expression (see the grammar at the top of this file) into an AST.
Throws [`QueryParseError`](@ref) on malformed input.
"""
function parse_query_expr(text::AbstractString)
    p = _QParser(_tokenize(text), 1)
    node = _parse_or(p)
    _peek(p).kind == :eof || throw(QueryParseError("unexpected token $(repr(_peek(p).text))", _peek(p).pos))
    return node
end

function _parse_or(p::_QParser)
    node = _parse_and(p)
    while _peek(p).kind == :or
        _advance!(p)
        node = QOr(node, _parse_and(p))
    end
    return node
end

function _parse_and(p::_QParser)
    node = _parse_atom(p)
    while _peek(p).kind == :and
        _advance!(p)
        node = QAnd(node, _parse_atom(p))
    end
    return node
end

function _parse_atom(p::_QParser)
    if _peek(p).kind == :lparen
        _advance!(p)
        node = _parse_or(p)
        _peek(p).kind == :rparen || throw(QueryParseError("expected ')'", _peek(p).pos))
        _advance!(p)
        return node
    end
    return _parse_cmp(p)
end

function _parse_cmp(p::_QParser)
    field_tok = _advance!(p)
    field_tok.kind in (:bareword, :number) ||
        throw(QueryParseError("expected a field name, got $(repr(field_tok.text))", field_tok.pos))
    op_tok = _advance!(p)
    op_tok.kind == :op ||
        throw(QueryParseError("expected a comparison operator (=, !=, <, <=, >, >=)", op_tok.pos))
    val_tok = _advance!(p)
    value = if val_tok.kind == :string
        val_tok.text
    elseif val_tok.kind == :number
        parse(Float64, val_tok.text)
    elseif val_tok.kind == :bareword
        lowercase(val_tok.text) == "true" ? true : lowercase(val_tok.text) == "false" ? false : val_tok.text
    else
        throw(QueryParseError("expected a value, got $(repr(val_tok.text))", val_tok.pos))
    end
    return QCmp(field_tok.text, _QOP_MAP[op_tok.text], value)
end

# ── Field resolution ───────────────────────────────────────────────────────────

# Pseudo-fields resolved specially rather than by `getfield` — either because the real
# field isn't directly comparable (`source::AbstractSource`) or because the shared display
# concept spans several fields (`_sampling_value`, see display.jl).
const _QUERY_FIELD_ALIASES = Dict{String, Symbol}(
    "dataset" => :__source, "source" => :__source,
    "r" => :acceleration, "accel" => :acceleration,
    "b0" => :field_strength,
    "channels" => :receiver_channels,
    "frames" => :num_frames,
    "size" => :approx_size_bytes,
    "sampling" => :__sampling,
)

const _QUERY_ENTRY_FIELDS = Dict(lowercase(String(f)) => f for f in fieldnames(DatasetEntry))

function _unknown_query_field(name::String, strict::Bool)
    msg = "query: field $(repr(name)) is neither a DatasetEntry field/alias nor a known " *
        "extra key of the queried sources — probably a typo; it will match no entry"
    strict ? error(msg) : @warn(msg)
    return nothing
end

# Resolved once per QCmp node at compile time (not per entry) — returns an `e -> value`
# accessor, so the per-entry hot loop never repeats the alias/field/extra lookup.
function _query_field_accessor(name::String, known_extra::Dict{String, String}, strict::Bool)
    key = lowercase(name)
    alias = get(_QUERY_FIELD_ALIASES, key, nothing)
    alias === :__source && return e -> source_name(e.source)
    alias === :__sampling && return e -> _sampling_value(e)
    alias !== nothing && return e -> getfield(e, alias)
    fsym = get(_QUERY_ENTRY_FIELDS, key, nothing)
    fsym !== nothing && return e -> getfield(e, fsym)
    extra_key = get(known_extra, key, nothing)
    extra_key !== nothing && return e -> get(e.extra, extra_key, nothing)
    _unknown_query_field(name, strict)
    return e -> nothing
end

# ── Comparison semantics ─────────────────────────────────────────────────────

function _glob_to_regex(pattern::AbstractString)
    parts = split(pattern, '*')
    escaped = [replace(part, r"([.^$|()\[\]{}+?\\])" => s"\\\1") for part in parts]
    return Regex("^" * join(escaped, ".*") * "\$", "i")
end

_query_str(::Nothing) = nothing
_query_str(v::AbstractString) = v
_query_str(v::Symbol) = String(v)
_query_str(v) = string(v)

function _query_eq(v, lit::Bool)
    return v === lit
end
function _query_eq(v, lit::Real)
    v isa Real || return false
    vn = Float64(v)
    return !isnan(vn) && vn == Float64(lit)
end
function _query_eq(v, lit::AbstractString)
    s = _query_str(v)
    s === nothing && return false
    return occursin('*', lit) ? occursin(_glob_to_regex(lit), s) : lowercase(s) == lowercase(lit)
end

function _query_cmp(v, op::Symbol, lit)
    if op == :eq
        return _query_eq(v, lit)
    elseif op == :neq
        return !_query_eq(v, lit)
    end
    # Ordering comparisons are numeric-only; a non-numeric literal or field value never
    # satisfies one (mirrors Tachikoma's `apply_filter` for `:numeric` columns).
    lit isa Real || return false
    vn = v isa Real ? Float64(v) : nothing
    (vn === nothing || isnan(vn)) && return false
    ln = Float64(lit)
    op == :lt && return vn < ln
    op == :lte && return vn <= ln
    op == :gt && return vn > ln
    op == :gte && return vn >= ln
    return false
end

# ── Compilation ────────────────────────────────────────────────────────────────

"""
    _compile_query_expr(node::QueryNode, sources; strict = false) -> Function

Compile a parsed query AST into one `e::DatasetEntry -> Bool` predicate, resolving field
names (aliases, `DatasetEntry` fields, then `extra_schema` keys of `sources`) once rather
than per entry.
"""
function _compile_query_expr(node::QueryNode, sources; strict::Bool = false)
    known_extra = Dict{String, String}()
    for s in sources, k in keys(extra_schema(s))
        known_extra[lowercase(k)] = k
    end
    return _compile_node(node, known_extra, strict)
end

function _compile_node(n::QAnd, known_extra, strict)
    l = _compile_node(n.l, known_extra, strict)
    r = _compile_node(n.r, known_extra, strict)
    return e -> l(e) && r(e)
end

function _compile_node(n::QOr, known_extra, strict)
    l = _compile_node(n.l, known_extra, strict)
    r = _compile_node(n.r, known_extra, strict)
    return e -> l(e) || r(e)
end

function _compile_node(n::QCmp, known_extra, strict)
    getval = _query_field_accessor(n.field, known_extra, strict)
    op = n.op
    lit = n.value
    return e -> _query_cmp(getval(e), op, lit)
end

# ── Public entry point ───────────────────────────────────────────────────────

"""
    query(text::AbstractString; sources = list_sources(), offline = false, strict = false)
        -> Vector{DatasetEntry}

The string-expression counterpart of the keyword form of [`query`](@ref): parse `text` as
a boolean expression and return the matching entries.

# Grammar
```
or_expr  := and_expr (OR and_expr)*
and_expr := atom (AND atom)*
atom     := '(' or_expr ')' | field OP value
OP       := '=' | '!=' | '<' | '<=' | '>' | '>='
```
`AND`/`OR` are case-insensitive and `AND` binds tighter than `OR`; parenthesize to
override. A value is a bare word, a `'single'`/`"double"`-quoted string, or a number.
A string containing `*` is matched as a case-insensitive glob (`*` → any run of
characters, anchored); without `*` it's an exact case-insensitive compare. `<`/`<=`/`>`/`>=`
compare numerically and never match a non-numeric or missing field.

`field` accepts any [`DatasetEntry`](@ref) field name, a friendly alias matching the
browser's column headers (`dataset`/`source`, `r`/`accel` → `acceleration`, `b0` →
`field_strength`, `channels` → `receiver_channels`, `frames` → `num_frames`, `size` →
`approx_size_bytes`, `sampling` → the same fully-sampled/pattern value the browser
displays), or a per-source `extra` key (see [`extra_schema`](@ref)) — all case-insensitive.
`strict = true` errors on an unknown field instead of `@warn`ing and matching nothing.

# Examples
```julia
query("dataset=fastmri AND R<3")
query("id='fs_*'")
query("(anatomy=knee AND R<3) OR fully_sampled=true")
```
"""
function query(
        text::AbstractString;
        sources = list_sources(),
        offline::Bool = false,
        strict::Bool = false,
    )
    srcs = sources isa AbstractSource ? (sources,) : sources
    pred = _compile_query_expr(parse_query_expr(text), srcs; strict = strict)
    out = DatasetEntry[]
    for s in srcs
        for e in _catalog_entries(s; offline = offline)
            pred(e) && push!(out, e)
        end
    end
    return out
end
