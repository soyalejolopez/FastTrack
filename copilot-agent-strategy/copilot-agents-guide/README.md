---
title: Copilot Agents Guide
type: strategy
category: Interactive
summary: >-
  Compare Microsoft Copilot agent platforms with capability views, decision guidance, support
  indicators, and adjacent experiences.
author: Microsoft FastTrack
version: 3.7.0
published: "2025-10-28"
updated: "2026-09-07"
tags:
  - guide
  - decision
  - planning
format: interactive
featured: true
whatItIs: >-
  A self-contained interactive web guide that compares Microsoft Copilot agent types across
  capabilities, constraints, technical effort, cost, and FastTrack support.
whyUseIt:
  - Shortlist an agent platform based on use case, team skills, budget, timeline, and growth.
  - Compare capabilities and limitations side by side before committing to a build path.
  - Give business, architecture, and development stakeholders a shared decision framework.
howToUse: >-
  Open `index.html` directly in a modern browser. To host locally, run `python -m http.server 8000`
  from the resource folder and browse to `http://localhost:8000/index.html`. Use the Overview,
  Guidance, Capabilities, Comparison, Labs, and Message Center tabs.
prerequisites:
  - Modern web browser
---

# Microsoft Copilot Agents Guide

An interactive decision-making dashboard to help you choose the right Microsoft Copilot agent platform for your business needs.

## 🎯 What Is This?

The **Copilot Agents Guide** is a comprehensive, interactive web-based tool that compares all Microsoft Copilot agent types in one place. Whether you're a business leader evaluating options, an IT architect planning deployments, or a developer starting a new project, this guide helps you make informed decisions about which agent platform to use.

![Agents Guide Screenshots](./images/Recording%202025-10-28%20170002.gif)

## ✨ Features

### 📊 Interactive Comparison Dashboard
- **6 Agent Types** compared side-by-side
- **Real-time filtering** with search functionality
- **Visual cards** with key metrics and capabilities
- **Responsive design** works on desktop, tablet, and mobile

### 🧭 Six Comprehensive Views

#### 1. Overview Tab
- Detailed agent descriptions
- Time to market estimates
- Technical level requirements
- Key metrics (setup time, scalability, customization, maintenance)
- Use case recommendations

#### 2. Capabilities Tab
- ✅ Key capabilities for each agent type
- ❌ Limitations and considerations
- Side-by-side comparison layout

#### 3. Comparison Tab
- **Feature matrix** comparing all agents
- FastTrack support indicators
- Setup time, technical level, scalability
- External API and multi-channel support

#### 4. Guidance Tab
- **4-step decision flow** framework
- Business decision maker considerations
- Common scenarios with recommendations
- Time and cost breakdowns
- Key takeaways

#### 5. Labs Tab
- Hands-on Copilot Studio lab walkthroughs
- Practice scenarios for building and testing agents

#### 6. Message Center Tab
- Recent Microsoft 365 Copilot and agent service updates relevant to planning

### ⚡ FastTrack Support Indicators
- Subtle badges showing which agents qualify for Microsoft FastTrack remote guidance
- Link to official FastTrack service description
- 5 of 6 agent types include FastTrack remote guidance

## 🤖 Agent Types Covered

### 1. **First-Party Agents**
Built-in agents included with Microsoft 365 Copilot
- **Researcher:** Complex multi-step research across work data and the web. Supported models and modes can be selected in the Researcher agent, and when you add @Researcher in Copilot Chat on Windows and web
- **Analyst:** Data analysis with Python execution
- **Viva Engage Community Agent:** Answers community questions grounded in community conversations and SharePoint (Preview)
- **Workflows Agent:** Natural language task automation built on Power Automate templates
- **Availability:** Immediate (pre-pinned in M365 Copilot)
- **Cost:** Included with M365 Copilot license (Researcher: 25 queries per user per month)

### 2. **Agent Builder**
Low-code agents built within Microsoft 365 Copilot
- Natural language creation
- Quick prototyping
- Personal productivity focus

### 3. **Copilot Studio Full Custom Agents**
Advanced agents with complex workflows
- Multi-channel publishing
- Custom connectors
- Enterprise-grade features

### 4. **SharePoint Agents**
Site-specific intelligent assistants
- Automatic content indexing
- Permissions-aware
- Fastest to deploy (1-2 hours)

### 5. **Copilot Studio Full Declarative Agents**
M365 Copilot-orchestrated agents
- Uses M365 Copilot's orchestrator
- Plugin actions
- Enterprise knowledge integration

### 6. **Microsoft 365 Agents Toolkit**
Pro-code development with full control
- TypeScript/JavaScript
- Visual Studio Code
- CI/CD support
- **Note:** Self-service only (no FastTrack support)

## 🧩 Adjacent Experiences Covered

These are not agent-building platforms, so they are not counted among the six agent types. The guide covers them because they affect planning, licensing, and governance decisions.

### **Copilot Cowork**
Delegated, multi-step knowledge work across Microsoft 365
- Generally available to Microsoft 365 Copilot tenants in tier-1 languages, with use and access currently limited to Anthropic-supported regions
- Access is granted through a spending policy that selects Cowork; consumption is billed in Copilot Credits
- Supports scheduled prompts and event-driven tasks that run when a matching email or Teams message arrives
- FastTrack publishes a **separate Cowork scope** covering fundamentals, consumption guidance, configuring Cowork and billing policies, and validating usage-based billing, spending policies, and monitoring

### **Microsoft Agent 365**
Control plane for observing, securing, and governing agents at scale

### **Microsoft Scout** (Preview)
Desktop AI application available only through the Frontier preview program
- Requires both a Microsoft 365 Copilot license and a GitHub Copilot Business or Enterprise seat
- Not available in US Government, sovereign, or national clouds

## 🚀 How to Use

### Option 1: Open Directly
Simply open `index.html` in any modern web browser.

### Option 2: Host Locally
```bash
# Navigate to the directory
cd copilot-agent-strategy/copilot-agents-guide/

# Open with Python's built-in server
python -m http.server 8000

# Or with Node.js
npx http-server

# Then open http://localhost:8000/index.html
```

### Option 3: Deploy to Web Server
Upload the HTML file to any web server or hosting platform:
- GitHub Pages
- Azure Static Web Apps
- SharePoint
- Internal corporate web server

## 📋 User Guide

### For Business Leaders
1. **Start with Overview** - Understand each agent type's value proposition
2. **Check Guidance Tab** - Review the 4-step decision framework
3. **Compare Costs** - See time-to-market and licensing requirements
4. **Consider FastTrack** - Note which agents include remote guidance

### For IT Architects
1. **Review Comparison Tab** - Analyze technical capabilities side-by-side
2. **Check Scalability** - Match agent types to your growth plans
3. **Evaluate Integration** - See which platforms support external APIs
4. **Plan Deployment** - Use FastTrack indicators for implementation planning

### For Developers
1. **Explore Capabilities** - Understand what each platform can do
2. **Review Limitations** - Know the constraints before committing
3. **Check Technical Level** - Match to your team's skills
4. **Read Use Cases** - Find scenarios similar to your requirements

## 🔍 Search & Filter

Use the search bar to quickly find:
- **By capability:** "Python", "API", "SharePoint", "reasoning"
- **By use case:** "research", "customer service", "data analysis"
- **By deployment:** "quick", "fast", "immediate"
- **By requirement:** "multi-channel", "connectors", "custom"

## 💡 Decision Framework

The guide includes a proven 4-step framework:

1. **Start with Your Use Case** - Match your needs to agent capabilities
2. **Evaluate Team's Capabilities** - Consider technical skill requirements
3. **Consider Budget & Timeline** - Balance cost and time-to-market
4. **Plan for Growth & Support** - Think about scaling and FastTrack assistance

## 🎨 Technical Details

### Technologies Used
- **React 18** - Component-based UI
- **Tailwind CSS** - Utility-first styling
- **Lucide Icons** - Modern icon library
- **Pure JavaScript** - No build process required
- **Single HTML File** - Self-contained, easy to share

### Browser Compatibility
- ✅ Chrome/Edge (recommended)
- ✅ Firefox
- ✅ Safari
- ✅ Mobile browsers

### Performance
- Lightweight (~200KB total)
- Instant loading
- No external dependencies beyond CDN resources
- Fully client-side (no backend required)

## 📚 Information Sources

All agent information verified from official Microsoft sources:
- Microsoft 365 Copilot documentation
- Microsoft Copilot Studio documentation
- Microsoft 365 Agents Toolkit GitHub repository
- FastTrack for Microsoft 365 service descriptions
- Official Microsoft 365 Blog announcements

**Last Verified:** September 2026

## 🔄 Updates & Maintenance

This guide is updated to reflect:
- Latest Microsoft agent offerings
- Current FastTrack support scope
- Recent feature additions (like Researcher & Analyst agents)
- Updated pricing and licensing information

**Check back regularly** for updates as Microsoft continues to expand its Copilot agent ecosystem.

## ⚠️ Important Notes

### FastTrack Remote Guidance
- 5 of 6 agent types qualify for FastTrack remote guidance
- Custom engine agents are covered only when the deployment channel is Teams, Microsoft 365 Copilot, or SharePoint
- Microsoft 365 Agents Toolkit (pro-code) is self-service only
- See footer link for detailed FastTrack service description

## 🤝 Feedback & Contributions

### Found an Issue?
- Agent information outdated?
- Feature not working as expected?
- Accessibility concerns?

Please provide feedback so we can improve the guide!

### Suggestions for Improvement
We're always looking to enhance the guide with:
- Additional comparison metrics
- More detailed use cases
- Better decision frameworks
- Links to implementation guides
- Success stories and examples

## 📖 Related Resources

### In This Repository
- **[Agent Brainstorming Template](../copilot-agent-brainstorm/)** - Plan your specific agent implementation
- **[Strategy Resources](../)** - Additional planning and governance tools

### Official Microsoft Links
- [Microsoft 365 Copilot](https://www.microsoft.com/microsoft-365/copilot)
- [Microsoft Copilot Studio](https://www.microsoft.com/microsoft-copilot-studio)
- [Microsoft 365 Agents Toolkit](https://github.com/officedev/microsoft-365-agents-toolkit)
- [FastTrack for Microsoft 365](https://learn.microsoft.com/en-us/microsoft-365/fasttrack/)
- [FastTrack scope — Microsoft 365 Copilot](https://learn.microsoft.com/en-us/microsoft-365/fasttrack/microsoft-365-copilot#microsoft-copilot-agents)
- [FastTrack scope — Microsoft Copilot Cowork](https://learn.microsoft.com/en-us/microsoft-365/fasttrack/microsoft-365-copilot#microsoft-copilot-cowork)
- [FastTrack scope — Microsoft Agent 365](https://learn.microsoft.com/en-us/microsoft-365/fasttrack/microsoft-agent-365)
- [Microsoft Agent 365 overview](https://learn.microsoft.com/en-us/microsoft-agent-365/overview)
- [Compare Microsoft 365 E3, E5, and E7 license features](https://learn.microsoft.com/en-us/microsoft-365/copilot/microsoft-365-copilot-license-feature-overview)
- [People Skills overview](https://learn.microsoft.com/en-us/microsoft-365/copilot/people-skills-overview)
- [Microsoft Entra Agent ID in Copilot Studio](https://learn.microsoft.com/en-us/microsoft-copilot-studio/admin-use-entra-agent-identities)
- [Extend your agent with Model Context Protocol](https://learn.microsoft.com/en-us/microsoft-copilot-studio/agent-extend-action-mcp)
- [Microsoft 365 Copilot release notes](https://learn.microsoft.com/en-us/microsoft-365/copilot/release-notes)
- [Copilot Cowork FAQ](https://learn.microsoft.com/en-us/microsoft-365/copilot/cowork/cowork-faq)
- [What's new in Copilot Cowork](https://learn.microsoft.com/en-us/microsoft-365/copilot/cowork/whats-new)
- [Use the local browser in Copilot Cowork](https://learn.microsoft.com/en-us/microsoft-365/copilot/cowork/cowork-local-browser)
- [Manage Copilot Cowork for your organization](https://learn.microsoft.com/en-us/microsoft-365/copilot/cowork/cowork-admin-governance)
- [Use Copilot Cowork](https://learn.microsoft.com/en-us/microsoft-365/copilot/cowork/use-cowork)
- [Get started with Microsoft Scout](https://learn.microsoft.com/en-us/microsoft-scout/get-started)
- [Admin access overview for Microsoft Scout](https://learn.microsoft.com/en-us/microsoft-scout/admin-access-overview)
- [Responsible AI FAQ for Microsoft Scout](https://learn.microsoft.com/en-us/microsoft-scout/microsoft-scout-responsible-ai-faq)
- [What's new in Microsoft Scout](https://learn.microsoft.com/en-us/microsoft-scout/whats-new)
- [Researcher agent FAQ](https://learn.microsoft.com/en-us/microsoft-365/copilot/faq-researcher)
- [Cost considerations for agents](https://learn.microsoft.com/en-us/microsoft-365/copilot/extensibility/cost-considerations)
- [Researcher & Analyst Announcement](https://www.microsoft.com/en-us/microsoft-365/blog/2025/03/25/introducing-researcher-and-analyst-in-microsoft-365-copilot/)
- [Wave 3 — Powering Frontier Transformation](https://www.microsoft.com/en-us/microsoft-365/blog/2026/03/09/powering-frontier-transformation-with-copilot-and-agents/)
- [Copilot Cowork Announcement](https://www.microsoft.com/en-us/microsoft-365/blog/2026/03/09/copilot-cowork-a-new-way-of-getting-work-done/)

## 📄 License

This guide is provided as-is for informational and planning purposes. Microsoft, Microsoft 365, Copilot, and related trademarks are property of Microsoft Corporation.

---

**Version:** 3.7 (September 2026)  
**Includes:** Copilot Cowork access corrected to a spending policy that selects Cowork (the deprecated agent-level enablement wording is removed), the separate FastTrack Cowork scope and the Request for Assistance fallback documented, Cowork event-driven tasks added, the stale Researcher model picker limitation removed now that model and mode selection is available when adding @Researcher in Copilot Chat, the disputed Entra Agent ID rollout date removed with the standard-harness qualifier and optional manual migration added, and Microsoft Scout added as a preview adjacent experience  
**Format:** Single-file HTML application  

*Built to help you navigate the Microsoft Copilot agent ecosystem with confidence.*