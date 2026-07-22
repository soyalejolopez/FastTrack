import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, relative, sep } from 'node:path';
import { fileURLToPath } from 'node:url';
import Ajv2020 from 'ajv/dist/2020.js';
import matter from 'gray-matter';
import yaml from 'js-yaml';

const toolDirectory = dirname(fileURLToPath(import.meta.url));
const repositoryRoot = join(toolDirectory, '..', '..');
const checkOnly = process.argv.includes('--check');
const resourceSchema = JSON.parse(readFileSync(join(toolDirectory, 'resource.schema.json'), 'utf8'));
const legacyExclusionDocument = JSON.parse(readFileSync(join(toolDirectory, 'legacy-exclusions.json'), 'utf8'));
const legacyExclusions = Array.isArray(legacyExclusionDocument) ? legacyExclusionDocument : [];
const validateResourceSchema = new Ajv2020({ allErrors: true, strict: true }).compile(resourceSchema);

const folderRoots = [
  'scripts',
  'copilot-agent-samples/copilot-studio-agents',
  'copilot-agent-samples/agent-builder-agents',
  'copilot-agent-samples/github-copilot-agents',
  'copilot-agent-samples/github-copilot-skills',
  'copilot-agent-strategy',
  'copilot-analytics-samples'
];
const promptRoot = 'copilot-prompt-samples';
const excludedSegments = new Set(['archive', '_sample_templates', 'samples']);
const allowedTypes = new Set(['script', 'agent', 'strategy', 'analytics', 'prompt', 'skill']);
const allowedFormats = new Set(['ps1', 'bundle', 'declarative', 'interactive', 'pptx', 'pbix', 'md']);
const allowedStatuses = new Set(['active', 'preview', 'archived']);
const semverPattern = /^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$/;
const datePattern = /^\d{4}-\d{2}-\d{2}$/;

function toPosix(path) {
  return path.split(sep).join('/');
}

function isExcluded(path) {
  return toPosix(relative(repositoryRoot, path))
    .toLowerCase()
    .split('/')
    .some(segment => excludedSegments.has(segment));
}

function collectReadmes(directory, files = []) {
  if (!existsSync(directory) || isExcluded(directory)) return files;

  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    const path = join(directory, entry.name);
    if (isExcluded(path)) continue;
    if (entry.isDirectory()) collectReadmes(path, files);
    else if (entry.name.toLowerCase() === 'readme.md') files.push(path);
  }
  return files;
}

function collectCandidates() {
  const files = folderRoots.flatMap(root => collectReadmes(join(repositoryRoot, ...root.split('/'))));
  const promptsDirectory = join(repositoryRoot, promptRoot);

  if (existsSync(promptsDirectory)) {
    for (const entry of readdirSync(promptsDirectory, { withFileTypes: true })) {
      if (entry.isFile() && entry.name.toLowerCase().endsWith('.md') && entry.name.toLowerCase() !== 'readme.md') {
        files.push(join(promptsDirectory, entry.name));
      }
    }
  }

  return [...new Set(files)].sort();
}

function hasFrontMatter(source) {
  return source.replace(/^\uFEFF/, '').startsWith('---\n') ||
    source.replace(/^\uFEFF/, '').startsWith('---\r\n');
}

function parseFrontMatter(source) {
  return matter(source, {
    engines: {
      yaml: input => yaml.load(input, { schema: yaml.JSON_SCHEMA })
    }
  }).data;
}

function isNonEmptyString(value) {
  return typeof value === 'string' && value.trim().length > 0;
}

function isStringList(value) {
  return Array.isArray(value) && value.length > 0 && value.every(isNonEmptyString);
}

function isValidDate(value) {
  if (!isNonEmptyString(value) || !datePattern.test(value)) return false;
  const parsed = new Date(`${value}T00:00:00Z`);
  return !Number.isNaN(parsed.valueOf()) && parsed.toISOString().slice(0, 10) === value;
}

function gitUpdatedDate(file) {
  const relativePath = toPosix(relative(repositoryRoot, file));
  try {
    return execFileSync('git', ['log', '-1', '--format=%cs', '--', relativePath], {
      cwd: repositoryRoot,
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore']
    }).trim();
  } catch {
    return '';
  }
}

function hasRawHtmlTags(value) {
  return typeof value === 'string' && /[<>]/.test(value);
}

function validate(data, file) {
  const errors = [];
  const add = (field, message) => errors.push({ file, field, message });

  if (!validateResourceSchema(data)) {
    for (const error of validateResourceSchema.errors) {
      const field = error.params.missingProperty ??
        error.instancePath.slice(1).replaceAll('/', '.') ??
        'front matter';
      add(field || 'front matter', error.message);
    }
  }

  for (const field of ['title', 'type', 'category', 'summary', 'author', 'version', 'published']) {
    if (data[field] === undefined || data[field] === null || data[field] === '') {
      add(field, 'is required');
    }
  }

  if (data.title !== undefined) {
    if (!isNonEmptyString(data.title)) add('title', 'must be a non-empty string');
    else if ([...data.title].length > 100) add('title', `must be 100 characters or fewer (found ${[...data.title].length})`);
    else if (hasRawHtmlTags(data.title)) add('title', 'must not contain raw < or >');
  }
  if (data.type !== undefined && !allowedTypes.has(data.type)) add('type', `must be one of: ${[...allowedTypes].join(', ')}`);
  if (data.category !== undefined) {
    if (!isNonEmptyString(data.category)) add('category', 'must be a non-empty string');
    else if ([...data.category].length > 100) add('category', `must be 100 characters or fewer (found ${[...data.category].length})`);
    else if (hasRawHtmlTags(data.category)) add('category', 'must not contain raw < or >');
  }
  if (data.summary !== undefined) {
    if (!isNonEmptyString(data.summary)) add('summary', 'must be a non-empty string');
    else if ([...data.summary].length > 140) add('summary', `must be 140 characters or fewer (found ${[...data.summary].length})`);
    else if (hasRawHtmlTags(data.summary)) add('summary', 'must not contain raw < or >');
  }
  if (data.author !== undefined) {
    if (!isNonEmptyString(data.author) && !isStringList(data.author)) {
      add('author', 'must be a non-empty string or a non-empty list of strings');
    } else {
      const authors = Array.isArray(data.author) ? data.author : [data.author];
      for (const author of authors) {
        if ([...author].length > 100) add('author', `author string must be 100 characters or fewer (found ${[...author].length})`);
        if (hasRawHtmlTags(author)) add('author', 'author must not contain raw < or >');
      }
    }
  }
  if (data.version !== undefined && (!isNonEmptyString(data.version) || !semverPattern.test(data.version))) {
    add('version', 'must be a semantic version such as 1.0.0');
  }
  if (data.published !== undefined && !isValidDate(data.published)) add('published', 'must use YYYY-MM-DD');
  if (data.updated !== undefined && !isValidDate(data.updated)) add('updated', 'must use YYYY-MM-DD');
  const today = new Date().toISOString().slice(0, 10);
  if (isValidDate(data.published) && data.published > today) add('published', 'must not be in the future');
  if (isValidDate(data.updated) && data.updated > today) add('updated', 'must not be in the future');
  if (isValidDate(data.published) && isValidDate(data.updated) && data.updated < data.published) {
    add('updated', 'must be on or after published');
  }
  if (data.tags !== undefined) {
    if (!isStringList(data.tags)) add('tags', 'must be a non-empty list of strings');
    else {
      if (new Set(data.tags).size !== data.tags.length) add('tags', 'must contain unique values');
      for (const tag of data.tags) {
        if (tag !== tag.toLowerCase()) add('tags', `tag "${tag}" must be lowercase`);
        if ([...tag].length > 50) add('tags', `tag must be 50 characters or fewer (found ${[...tag].length})`);
        if (hasRawHtmlTags(tag)) add('tags', 'tag must not contain raw < or >');
      }
    }
  }
  if (data.format !== undefined) {
    if (!allowedFormats.has(data.format)) add('format', `must be one of: ${[...allowedFormats].join(', ')}`);
    else if (hasRawHtmlTags(data.format)) add('format', 'must not contain raw < or >');
  }
  if (data.featured !== undefined && typeof data.featured !== 'boolean') add('featured', 'must be true or false');
  if (data.status !== undefined && !allowedStatuses.has(data.status)) add('status', `must be one of: ${[...allowedStatuses].join(', ')}`);
  if (data.whatItIs !== undefined && !isNonEmptyString(data.whatItIs)) add('whatItIs', 'must be a non-empty string');
  if (data.whyUseIt !== undefined && !isStringList(data.whyUseIt)) add('whyUseIt', 'must be a non-empty list of strings');
  if (data.howToUse !== undefined && !isNonEmptyString(data.howToUse)) add('howToUse', 'must be a non-empty Markdown string');
  if (data.prerequisites !== undefined && !isStringList(data.prerequisites)) add('prerequisites', 'must be a non-empty list of strings');
  if (data.url !== undefined) {
    if (typeof data.url !== 'string') {
      add('url', 'must be a string');
    } else {
      const trimmedUrl = data.url.trim();
      const hasDisallowedScheme = /^[a-z][a-z\d+.-]*:/i.test(trimmedUrl) &&
        !/^https?:\/\//i.test(trimmedUrl);
      const isAllowedUrl = trimmedUrl.length > 0 && !hasDisallowedScheme &&
        !trimmedUrl.startsWith('//') && !/[\\\s]/.test(trimmedUrl);
      if (!isAllowedUrl) {
        add('url', 'must be an HTTP(S) or relative URL');
      } else {
        try {
          if (trimmedUrl.startsWith('http')) {
            const url = new URL(trimmedUrl);
            if (url.protocol !== 'https:' && url.protocol !== 'http:') add('url', 'must be an HTTP(S) URL');
          }
        } catch {
          add('url', 'must be a valid URL');
        }
      }
    }
  }

  return errors;
}

function deriveUrl(file) {
  const relativePath = toPosix(relative(repositoryRoot, file));
  const isPrompt = relativePath.startsWith(`${promptRoot}/`);
  const target = isPrompt ? relativePath : relativePath.replace(/\/readme\.md$/i, '');
  const encodedTarget = target.split('/').map(encodeURIComponent).join('/');
  return `https://github.com/microsoft/FastTrack/${isPrompt ? 'blob' : 'tree'}/master/${encodedTarget}`;
}

function slugify(value) {
  return value.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/(^-|-$)/g, '');
}

function createResource(data, file, updated) {
  const relativePath = toPosix(relative(repositoryRoot, file));
  const resource = {
    name: data.title,
    title: data.title,
    slug: slugify(data.title),
    type: data.type,
    subcategory: data.category,
    category: data.category,
    description: data.summary,
    summary: data.summary,
    tags: data.tags ?? [],
    artifact: data.format ?? 'md',
    format: data.format ?? 'md',
    featured: data.featured ?? false,
    status: data.status ?? 'active',
    author: data.author,
    version: data.version,
    published: data.published,
    updated,
    whatItIs: data.whatItIs,
    whyUseIt: data.whyUseIt ?? [],
    howToUse: data.howToUse,
    prerequisites: data.prerequisites ?? [],
    url: data.url ?? deriveUrl(file),
    source: relativePath
  };

  return Object.fromEntries(Object.entries(resource).filter(([, value]) => value !== undefined));
}

const candidates = collectCandidates();
const resources = [];
const errors = [];
const candidatePaths = new Set(candidates.map(file => toPosix(relative(repositoryRoot, file))));
const legacyExclusionSet = new Set(legacyExclusions);

if (!Array.isArray(legacyExclusionDocument) || legacyExclusionSet.size !== legacyExclusions.length ||
    !legacyExclusions.every(path => typeof path === 'string' && path.length > 0)) {
  errors.push({
    file: join(toolDirectory, 'legacy-exclusions.json'),
    field: 'manifest',
    message: 'must be an array of unique, non-empty repository-relative paths'
  });
}

for (const file of candidates) {
  const source = readFileSync(file, 'utf8');
  const relativePath = toPosix(relative(repositoryRoot, file));
  if (!hasFrontMatter(source)) {
    if (!legacyExclusionSet.has(relativePath)) {
      errors.push({ file, field: 'front matter', message: 'is required for new catalog candidates' });
    }
    continue;
  }

  let data;
  try {
    data = parseFrontMatter(source);
  } catch (error) {
    errors.push({ file, field: 'front matter', message: error.message });
    continue;
  }

  const updated = data.updated ?? gitUpdatedDate(file);
  if (!updated) errors.push({ file, field: 'updated', message: 'is required or must be derivable from Git history' });
  else data.updated = updated;
  errors.push(...validate(data, file));

  if (!errors.some(error => error.file === file)) {
    resources.push(createResource(data, file, updated));
  }
}

for (const excludedPath of legacyExclusionSet) {
  const file = join(repositoryRoot, ...excludedPath.split('/'));
  if (!candidatePaths.has(excludedPath) || !existsSync(file)) {
    errors.push({ file, field: 'legacy exclusion', message: 'does not identify an eligible README' });
  } else if (hasFrontMatter(readFileSync(file, 'utf8'))) {
    errors.push({ file, field: 'legacy exclusion', message: 'must be removed after front matter is added' });
  }
}

const resourcesBySlug = new Map();
for (const resource of resources) {
  const existing = resourcesBySlug.get(resource.slug);
  if (existing) {
    errors.push({
      file: join(repositoryRoot, ...resource.source.split('/')),
      field: 'title',
      message: `normalizes to duplicate slug "${resource.slug}" already used by ${existing.source}`
    });
  } else {
    resourcesBySlug.set(resource.slug, resource);
  }
}

if (resources.length === 0 && errors.length === 0) {
  errors.push({ file: repositoryRoot, field: 'catalog', message: 'contains no resources with YAML front matter' });
}

if (errors.length > 0) {
  console.error(`Catalog validation failed with ${errors.length} error${errors.length === 1 ? '' : 's'}:`);
  for (const error of errors) {
    console.error(`- ${toPosix(relative(repositoryRoot, error.file))}: ${error.field} ${error.message}`);
  }
  process.exitCode = 1;
} else if (checkOnly) {
  console.log(`Catalog metadata is valid for ${resources.length} resources.`);
} else {
  resources.sort((a, b) => a.title.localeCompare(b.title));
  const catalog = {
    generatedAt: new Date().toISOString(),
    count: resources.length,
    resources
  };
  const output = `${JSON.stringify(catalog, null, 2)}\n`;
  const rootOutput = join(repositoryRoot, 'catalog.json');
  const siteOutput = join(repositoryRoot, 'design-concepts', 'catalog.json');
  writeFileSync(rootOutput, output);
  if (existsSync(dirname(siteOutput))) writeFileSync(siteOutput, output);
  console.log(`Wrote ${resources.length} resources to ${toPosix(relative(repositoryRoot, rootOutput))} and design-concepts/catalog.json.`);
}
