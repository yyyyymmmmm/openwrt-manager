import SwiftUI
import OpenWrtKit

// MARK: - Package E shared components
//
// The comprehension layer's UI kit: every page builds its opening
// verdict, its rated metrics, its term explanations and its raw-data
// demotion from these pieces, so the five standards look and behave
// identically everywhere. Verdicts and grades come from the kit
// (SummaryEngine / HealthRating); these views only render them.

// MARK: Summary banner (standard 1: verdict first)

struct SummaryBanner: View {
    let summary: PageSummary

    var body: some View {
        HStack(alignment: .top, spacing: AppSpacing.sm) {
            Image(systemName: icon).font(.system(size: 17)).foregroundStyle(tint)
            Text(summary.headline)
                .font(AppTypography.reading.weight(.medium))
                .foregroundStyle(AppPalette.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(AppSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(soft, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }

    private var icon: String {
        switch summary.tone {
        case .good: return "checkmark.circle.fill"
        case .neutral: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .bad: return "xmark.octagon.fill"
        case .unknown: return "questionmark.circle.fill"
        }
    }

    private var tint: Color {
        switch summary.tone {
        case .good: return AppPalette.green
        case .neutral: return AppPalette.accent
        case .warning: return AppPalette.orange
        case .bad: return AppPalette.red
        case .unknown: return AppPalette.muted
        }
    }

    private var soft: Color {
        switch summary.tone {
        case .good: return AppPalette.greenSoft
        case .neutral: return AppPalette.accentSoft
        case .warning: return AppPalette.orangeSoft
        case .bad: return AppPalette.redSoft
        case .unknown: return AppPalette.canvas
        }
    }
}

extension View {
    /// SummaryBanner as a borderless list row (the tab pages are
    /// Lists; the banner brings its own card chrome).
    func summaryRow() -> some View {
        self.listRowInsets(EdgeInsets()).listRowBackground(Color.clear)
    }
}

// MARK: Grades (standard 2: numbers with a human rating)

extension HealthGrade {
    var tint: Color {
        switch self {
        case .excellent, .good: return AppPalette.green
        case .fair: return AppPalette.blue
        case .poor: return AppPalette.orange
        case .critical: return AppPalette.red
        case .unknown: return AppPalette.muted
        }
    }

    var soft: Color {
        switch self {
        case .excellent, .good: return AppPalette.greenSoft
        case .fair: return AppPalette.blueSoft
        case .poor: return AppPalette.orangeSoft
        case .critical: return AppPalette.redSoft
        case .unknown: return AppPalette.canvas
        }
    }
}

struct GradeChip: View {
    let grade: HealthGrade
    /// Strength metrics (signal) use the strength wording.
    var strength = false

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            Circle().fill(grade.tint).frame(width: 7, height: 7)
            Text(strength ? grade.strengthLabel : grade.label)
                .font(AppTypography.metadata.weight(.medium))
        }
        .foregroundStyle(grade.tint)
        .padding(.horizontal, AppSpacing.sm).padding(.vertical, 3)
        .background(grade.soft, in: Capsule())
    }
}

struct MeterBar: View {
    let fraction: Double
    let grade: HealthGrade

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(AppPalette.line)
                Capsule().fill(grade.tint)
                    .frame(width: proxy.size.width * CGFloat(min(max(fraction, 0), 1)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

/// StatusCard's rated sibling: the same card, plus a meter bar and a
/// grade chip, for the numbers a user cannot judge raw (memory,
/// storage, load…).
struct RatedMetricCard: View {
    let title: String
    let value: String
    var detail: String? = nil
    var symbol: String? = nil
    let fraction: Double?
    let grade: HealthGrade

    var body: some View {
        VStack(alignment: .leading, spacing: AppSpacing.sm) {
            HStack(spacing: AppSpacing.sm) {
                if let symbol {
                    Image(systemName: symbol).foregroundStyle(AppPalette.accent)
                }
                Text(L10n.key(title)).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                Spacer(minLength: 0)
                GradeChip(grade: grade)
            }
            Text(L10n.key(value)).font(AppTypography.title).foregroundStyle(AppPalette.text)
                .lineLimit(2).minimumScaleFactor(0.7)
            if let fraction {
                MeterBar(fraction: fraction, grade: grade)
            }
            if let detail {
                Text(L10n.key(detail)).font(AppTypography.metadata).foregroundStyle(AppPalette.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(AppSpacing.md)
        .background(AppPalette.surface, in: RoundedRectangle(cornerRadius: AppRadius.md))
    }
}

/// A plain labeled row whose value carries its grade chip — the
/// rated replacement for a bare LabeledContent on key numbers.
struct RatedRow: View {
    let title: String
    let value: String
    let grade: HealthGrade
    /// Strength metrics (signal) use the strength wording, same as
    /// GradeChip's own switch.
    var strength = false

    var body: some View {
        HStack(spacing: AppSpacing.sm) {
            Text(L10n.key(title)).font(AppTypography.row)
            Spacer(minLength: AppSpacing.sm)
            Text(value).font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
                .monospacedDigit()
            GradeChip(grade: grade, strength: strength)
        }
    }
}

// MARK: Term hints (standard 3: jargon explained in place)

/// A small "?" that explains one glossary term in a popover. Renders
/// nothing when the word is not in the glossary, so call sites can
/// attach it speculatively to labels.
struct TermHint: View {
    let term: String
    @State private var showing = false

    var body: some View {
        if let entry = Glossary.lookup(term) {
            Button { showing = true } label: {
                Image(systemName: "questionmark.circle").font(AppTypography.metadata)
            }
            .buttonStyle(.plain)
            .foregroundStyle(AppPalette.accent)
            .accessibilityLabel(L10n.format("查看「%@」的解释", entry.term))
            .popover(isPresented: $showing) {
                VStack(alignment: .leading, spacing: AppSpacing.sm) {
                    Text(entry.term).font(AppTypography.rowTitle).foregroundStyle(AppPalette.text)
                    Text(entry.explanation).font(AppTypography.secondary)
                        .foregroundStyle(AppPalette.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(AppSpacing.lg)
                .frame(maxWidth: 280, alignment: .leading)
                .presentationCompactAdaptation(.popover)
            }
        }
    }
}

/// A label followed by its term hint, for rows and headers whose
/// label is itself jargon.
struct TermLabel: View {
    let text: String
    let term: String

    var body: some View {
        HStack(spacing: AppSpacing.xs) {
            Text(L10n.key(text))
            TermHint(term: term)
        }
    }
}

// MARK: Raw data (standard 4: originals demoted, not deleted)

/// The collapsed home for raw material — full key/value dumps,
/// command output, file contents. The human layer sits above it;
/// this stays one tap away, closed by default.
struct RawDataSection<Content: View>: View {
    var title: String = "原始数据"
    @State private var expanded = false
    @ViewBuilder let content: Content

    var body: some View {
        Section {
            DisclosureGroup(isExpanded: $expanded) {
                content
            } label: {
                Text(L10n.key(title))
                    .font(AppTypography.secondary).foregroundStyle(AppPalette.muted)
            }
        }
    }
}
