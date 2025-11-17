# Contributing to Binsync

Thank you for your interest in contributing to Binsync! This document provides guidelines and instructions for contributing.

## Getting Started

1. Fork the repository
2. Clone your fork: `git clone https://github.com/YOUR_USERNAME/Binsync.git`
3. Create a new branch: `git checkout -b feature/your-feature-name`
4. Make your changes
5. Test your changes
6. Commit and push
7. Submit a Pull Request

## Development Setup

### Prerequisites
- Flutter SDK (3.0.0 or higher)
- Dart SDK (3.0.0 or higher)
- Git
- IDE (VS Code or Android Studio recommended)

### Setup
```bash
# Install dependencies
flutter pub get

# Run tests
flutter test

# Run the app
flutter run
```

## Code Style

### Flutter/Dart Guidelines
- Follow the [Dart Style Guide](https://dart.dev/guides/language/effective-dart/style)
- Use `flutter format` to format your code
- Run `flutter analyze` to check for issues
- Keep lines under 80 characters when possible
- Use meaningful variable and function names

### Code Organization
- Keep widgets small and focused
- Extract complex widgets into separate files
- Use const constructors where possible
- Document public APIs with doc comments

### Example
```dart
/// Displays a garbage bin marker on the map.
/// 
/// The [location] parameter specifies where to place the marker.
/// The [color] parameter determines the marker color.
class BinMarker extends StatelessWidget {
  const BinMarker({
    super.key,
    required this.location,
    this.color = Colors.red,
  });

  final LatLng location;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Icon(Icons.delete, color: color);
  }
}
```

## Testing

### Writing Tests
- Add tests for new features
- Maintain test coverage
- Write unit tests for business logic
- Write widget tests for UI components

### Running Tests
```bash
# Run all tests
flutter test

# Run specific test file
flutter test test/widget_test.dart

# Run with coverage
flutter test --coverage
```

## Pull Request Process

1. **Update Documentation**
   - Update README if adding features
   - Add code comments for complex logic
   - Update DOCUMENTATION.md if changing architecture

2. **Test Your Changes**
   - Ensure all tests pass
   - Add new tests for new features
   - Test on multiple platforms if possible

3. **Follow Commit Message Guidelines**
   - Use clear, descriptive commit messages
   - Start with a verb (Add, Fix, Update, Remove)
   - Keep first line under 50 characters
   - Provide details in body if needed

   Example:
   ```
   Add route planning feature
   
   - Implement shortest path algorithm
   - Add UI for route display
   - Include tests for path calculation
   ```

4. **Submit PR**
   - Provide clear description of changes
   - Reference related issues
   - Include screenshots for UI changes
   - Request review from maintainers

## Areas for Contribution

### High Priority
- GPS location tracking
- Route optimization algorithms
- Offline map support
- Backend integration

### Features
- Different marker types
- Filter and search functionality
- Statistics and analytics
- User authentication
- Multi-language support

### Improvements
- Performance optimization
- Better error handling
- Accessibility features
- Dark mode support

### Documentation
- API documentation
- Video tutorials
- Use case examples
- Translation

## Bug Reports

When reporting bugs, include:
- Clear description of the issue
- Steps to reproduce
- Expected vs actual behavior
- Screenshots if applicable
- Device/platform information
- Flutter version

Use this template:

```markdown
**Bug Description**
A clear description of the bug

**To Reproduce**
1. Step 1
2. Step 2
3. See error

**Expected Behavior**
What should happen

**Actual Behavior**
What actually happens

**Screenshots**
If applicable

**Environment**
- Device: [e.g. iPhone 12, Pixel 5]
- OS: [e.g. iOS 15, Android 12]
- Flutter version: [e.g. 3.10.0]
- App version: [e.g. 1.0.0]
```

## Feature Requests

When requesting features:
- Explain the use case
- Describe expected behavior
- Provide mockups if applicable
- Discuss implementation ideas

## Code Review

All contributions go through code review:
- Be open to feedback
- Respond to review comments
- Make requested changes promptly
- Ask questions if unclear

## Community Guidelines

- Be respectful and inclusive
- Help others learn and grow
- Provide constructive feedback
- Follow the code of conduct

## Questions?

- Open an issue for discussion
- Check existing issues and PRs
- Read the documentation
- Ask in pull request comments

## License

By contributing, you agree that your contributions will be licensed under the MIT License.

Thank you for contributing to Binsync! 🚀
