// bookmark-plan.js — BrowSync
// Dry run of an incoming bookmark sync. The sync logic runs against an
// in-memory copy of the tree that implements the parts of chrome.bookmarks
// it uses, recording every write. The browser is only touched by replaying
// that exact list, so what the user reviews is what gets written.
//
// ChromiumExtension/background/bookmark-plan.js and
// FirefoxExtension/background/bookmark-plan.js must stay identical
// (scripts/check-bookmark-plan-copies.sh).

const VIRTUAL_PREFIX = 'browsync-planned-';

/// The form the browser stores and searches a URL in (trailing slash on a
/// bare host, lower-case host, default port, percent-encoding). The URL
/// parser here is the browser's own, so this matches what it will store.
/// Comparing raw strings would see a "rewrite" on every sync of a URL that
/// arrives in another form, and never converge.
export function canonicalUrl(url) {
  if (url === undefined || url === null) return url;
  try {
    return new URL(url).href;
  } catch (e) {
    return url;
  }
}

export class BookmarkPlan {
  constructor(tree) {
    this.ops = [];
    this.nextVirtualId = 0;
    this.nodes = new Map();
    // Canonical URL -> IDs, so search does not scan every node.
    this.idsByUrl = new Map();
    const copy = (node, parentId) => {
      const own = {
        id: node.id,
        parentId,
        title: node.title || '',
        url: node.url,
        childIds: (node.children || []).map(child => child.id),
        isFolder: !node.url
      };
      this.nodes.set(node.id, own);
      this.indexUrl(own);
      for (const child of node.children || []) copy(child, node.id);
    };
    // Chrome's root is '0', Firefox's 'root________'.
    this.rootIds = (tree || []).map(root => root.id);
    for (const root of tree || []) copy(root, root.parentId);
  }

  indexUrl(node) {
    if (node.url === undefined) return;
    const key = canonicalUrl(node.url);
    if (!this.idsByUrl.has(key)) this.idsByUrl.set(key, new Set());
    this.idsByUrl.get(key).add(node.id);
  }

  unindexUrl(node) {
    if (node.url === undefined) return;
    this.idsByUrl.get(canonicalUrl(node.url))?.delete(node.id);
  }

  static isPlannedId(id) {
    return typeof id === 'string' && id.startsWith(VIRTUAL_PREFIX);
  }

  view(node) {
    const parent = this.nodes.get(node.parentId);
    const view = { id: node.id, parentId: node.parentId, title: node.title, index: parent ? parent.childIds.indexOf(node.id) : 0 };
    if (node.url !== undefined) view.url = node.url;
    return view;
  }

  async get(id) {
    const node = this.nodes.get(id);
    if (!node) throw new Error(`No node ${id}`);
    return [this.view(node)];
  }

  async getChildren(id) {
    const node = this.nodes.get(id);
    if (!node) throw new Error(`No node ${id}`);
    return node.childIds.map(childId => this.view(this.nodes.get(childId)));
  }

  async search(query) {
    const ids = this.idsByUrl.get(canonicalUrl(query?.url)) || new Set();
    return [...ids].map(id => this.view(this.nodes.get(id)));
  }

  tree(id) {
    const node = this.nodes.get(id);
    const result = this.view(node);
    if (!node.url) result.children = node.childIds.map(childId => this.tree(childId));
    return result;
  }

  async getTree() {
    return this.rootIds.map(id => this.tree(id));
  }

  detach(node) {
    const parent = this.nodes.get(node.parentId);
    if (parent) parent.childIds = parent.childIds.filter(id => id !== node.id);
  }

  attach(node, parentId, index) {
    const parent = this.nodes.get(parentId);
    if (!parent) throw new Error(`No parent ${parentId}`);
    const at = Number.isInteger(index) ? Math.min(Math.max(index, 0), parent.childIds.length) : parent.childIds.length;
    parent.childIds.splice(at, 0, node.id);
    node.parentId = parentId;
  }

  async update(id, changes) {
    const node = this.nodes.get(id);
    if (!node) throw new Error(`No node ${id}`);
    this.ops.push({ type: 'update', id, title: changes.title, url: changes.url });
    if (changes.title !== undefined) node.title = changes.title;
    if (changes.url !== undefined && node.url !== undefined) {
      this.unindexUrl(node);
      node.url = canonicalUrl(changes.url);
      this.indexUrl(node);
    }
    return this.view(node);
  }

  async move(id, destination) {
    const node = this.nodes.get(id);
    if (!node) throw new Error(`No node ${id}`);
    const parentId = destination.parentId ?? node.parentId;
    this.ops.push({ type: 'move', id, parentId: destination.parentId, index: destination.index });
    this.detach(node);
    this.attach(node, parentId, destination.index);
    return this.view(node);
  }

  async create(details) {
    const id = VIRTUAL_PREFIX + (this.nextVirtualId++);
    const node = { id, parentId: details.parentId, title: details.title || '', url: canonicalUrl(details.url), childIds: [], isFolder: !details.url };
    this.nodes.set(id, node);
    this.indexUrl(node);
    this.attach(node, details.parentId, details.index);
    this.ops.push({ type: 'create', id, parentId: details.parentId, title: details.title, url: details.url, index: details.index });
    return this.view(node);
  }

  async removeTree(id) {
    const node = this.nodes.get(id);
    if (!node) throw new Error(`No node ${id}`);
    this.ops.push({ type: 'removeTree', id });
    this.detach(node);
    const drop = nodeId => {
      const n = this.nodes.get(nodeId);
      if (!n) return;
      n.childIds.forEach(drop);
      this.unindexUrl(n);
      this.nodes.delete(nodeId);
    };
    drop(id);
  }

  async remove(id) {
    return this.removeTree(id);
  }
}

/// Applies a plan's recorded writes to the real bookmarks API, in order.
/// Returns planned (virtual) ID -> real ID for the nodes it created.
export async function replayPlan(plan, bookmarksApi) {
  const realIds = new Map();
  const real = id => realIds.get(id) || id;
  // Real ID -> planned ID, to check removals against the planned result.
  const plannedIdOf = id => {
    for (const [planned, actual] of realIds) if (actual === id) return planned;
    return id;
  };
  // The browser rejects an index past the end, where the plan clamps (e.g.
  // when two incoming bookmarks matched one node). Order is cosmetic, so a
  // rejected position is retried at the end rather than losing the write.
  const withIndexFallback = async (write, destination) => {
    try {
      return await write(destination);
    } catch (error) {
      if (destination.index === undefined) throw error;
      const { index, ...rest } = destination;
      return await write(rest);
    }
  };
  for (const op of ops(plan)) {
    try {
      switch (op.type) {
        case 'update':
          await bookmarksApi.update(real(op.id), { title: op.title, url: op.url });
          break;
        case 'move': {
          const destination = { index: op.index };
          if (op.parentId !== undefined) destination.parentId = real(op.parentId);
          await withIndexFallback(d => bookmarksApi.move(real(op.id), d), destination);
          break;
        }
        case 'create': {
          const created = await withIndexFallback(
            d => bookmarksApi.create(d),
            { parentId: real(op.parentId), title: op.title, url: op.url, index: op.index }
          );
          realIds.set(op.id, created.id);
          break;
        }
        case 'removeTree': {
          // Never remove anything the plan keeps: if an earlier write failed
          // (a create, or a move out of this folder), the subtree still holds
          // bookmarks that were only meant to move, not to be deleted.
          const subtree = (await bookmarksApi.getSubTree(real(op.id)).catch(() => []))[0];
          const keeps = [];
          const collect = node => {
            for (const child of node?.children || []) {
              if (plan.nodes.has(plannedIdOf(child.id))) keeps.push(child.id);
              collect(child);
            }
          };
          collect(subtree);
          if (keeps.length) {
            console.warn(`[BrowSync] Skipped a planned removal: ${keeps.length} bookmarks inside are kept by the plan`);
            break;
          }
          try {
            await bookmarksApi.removeTree(real(op.id));
          } catch (e) {
            await bookmarksApi.remove(real(op.id));
          }
          break;
        }
      }
    } catch (error) {
      // Same tolerance as the direct writes this replaces: one failed write
      // (e.g. a node the browser refuses to move) must not abort the rest;
      // removals guard themselves above.
      console.warn(`[BrowSync] Planned bookmark ${op.type} failed`, error);
    }
  }
  return realIds;
}

function ops(plan) {
  return plan.ops;
}

async function sha256Hex(text) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return [...new Uint8Array(digest)].map(byte => byte.toString(16).padStart(2, '0')).join('');
}

function scopeNodes(treeOrPlan, scopeRootIds) {
  // ID -> { parent, title, url, isFolder } for every node under the scope roots.
  const result = new Map();
  const visit = (node, parentId) => {
    result.set(node.id, { parent: parentId, title: node.title || '', url: canonicalUrl(node.url), isFolder: !node.url });
    for (const child of node.children || []) visit(child, node.id);
  };
  for (const rootId of scopeRootIds) {
    const root = treeOrPlan.find(rootId);
    if (!root) continue;
    for (const child of root.children || []) visit(child, rootId);
  }
  return result;
}

function finder(tree) {
  const byId = new Map();
  const index = node => { byId.set(node.id, node); (node.children || []).forEach(index); };
  (tree || []).forEach(index);
  return { find: id => byId.get(id) };
}

/// The same measure the app applies to Safari: existing items removed, moved
/// (own parent changed; contents travel along) or rewritten in place. Large
/// changes need the user's review before anything is written.
export function requiresConfirmation(impact) {
  const affected = impact.removed + impact.moved + impact.modified;
  return affected > Math.max(8, Math.floor(impact.total / 20));
}

/// Compares the tree before the plan with the planned result, within the
/// synced scope. Signatures are stable across recomputation: existing nodes
/// keep their IDs; planned nodes are described by content path.
export async function summarizePlan(beforeTree, plan, scopeRootIds) {
  const afterTree = await plan.getTree();
  const before = scopeNodes(finder(beforeTree), scopeRootIds);
  const after = scopeNodes(finder(afterTree), scopeRootIds);
  const stableIds = new Map();
  const stableId = id => {
    if (before.has(id) || scopeRootIds.includes(id)) return id;
    if (stableIds.has(id)) return stableIds.get(id);
    const node = after.get(id);
    if (!node) return '';
    const value = `${stableId(node.parent)}/${node.url !== undefined ? 'u:' + node.url : 'f:'}|${node.title}`;
    stableIds.set(id, value);
    return value;
  };
  let removed = 0, moved = 0, modified = 0;
  const changes = [];
  const changeOf = new Map();
  for (const [id, node] of before) {
    const next = after.get(id);
    if (!next) {
      removed++;
      changes.push(`-${id}`);
      changeOf.set(id, 'removed');
      continue;
    }
    if (next.parent !== node.parent) {
      moved++;
      changes.push(`>${id}@${stableId(next.parent)}`);
      changeOf.set(id, 'moved');
    } else if (next.title !== node.title || next.url !== node.url) {
      modified++;
      changes.push(`~${id}=${next.url ?? ''}|${next.title}`);
      changeOf.set(id, 'modified');
    }
    if (next.parent !== node.parent && (next.title !== node.title || next.url !== node.url)) {
      modified++;
      changes.push(`~${id}=${next.url ?? ''}|${next.title}`);
    }
  }
  const destructive = changes.slice().sort();
  const additions = [];
  for (const id of after.keys()) {
    if (!before.has(id)) {
      additions.push(`+${stableId(id)}`);
      changeOf.set(id, 'added');
    }
  }
  additions.sort();
  const impact = { removed, moved, modified, total: before.size };
  return {
    impact,
    signature: await sha256Hex(destructive.concat(additions).join('\n')),
    destructiveSignature: await sha256Hex(destructive.join('\n')),
    // Built only for a held change; most syncs never need the trees.
    preview: () => ({
      before: previewTrees(beforeTree, scopeRootIds, changeOf, 'before'),
      after: previewTrees(afterTree, scopeRootIds, changeOf, 'after')
    })
  };
}

function previewTrees(tree, scopeRootIds, changeOf, side) {
  const { find } = finder(tree);
  const build = node => {
    let change = changeOf.get(node.id) || 'unchanged';
    if (side === 'before' && change === 'added') change = 'unchanged';
    if (side === 'after' && change === 'removed') change = 'unchanged';
    return {
      id: `${side}-${node.id}`,
      title: node.title || '',
      url: node.url ?? null,
      isFolder: !node.url,
      change,
      children: (node.children || []).map(build)
    };
  };
  return scopeRootIds.map(find).filter(Boolean).map(root => ({ ...build(root), change: 'unchanged' }));
}
